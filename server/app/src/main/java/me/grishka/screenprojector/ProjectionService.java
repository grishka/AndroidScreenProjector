package me.grishka.screenprojector;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.graphics.Point;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;
import android.util.Log;
import android.view.Display;
import android.view.Surface;
import android.view.WindowManager;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * Created by grishka on 08.10.2017.
 */

public class ProjectionService extends Service implements DisplayManager.DisplayListener{

	private static final String TAG="ProjectionService";

	private static final int ID_NOTIFICATION=20;
	private static ProjectionService instance;

	private MediaProjectionManager projectionManager;
	private MediaProjection projection;
	private Intent projectionData;
	private VirtualDisplay virtualDisplay;
	private MediaCodec codec;
	private Surface surface;
	private MediaFormat format;
	private MediaCodec.Callback codecCallback;

	private ServerSocket serverSocket;
	private Socket currentClientSocket;
	private DataOutputStream currentClientStream;
	private boolean codecReleased;
	private LinkedBlockingQueue<EncodedBuffer> buffersToSend=new LinkedBlockingQueue<>();
	private final ArrayList<EncodedBuffer> emptyBuffers=new ArrayList<>();
	private HandlerThread encoderThread=new HandlerThread("ProjectionEncoder", Process.THREAD_PRIORITY_URGENT_DISPLAY);

	@Override
	public IBinder onBind(Intent intent){
		return null;
	}

	@Override
	public int onStartCommand(Intent intent, int flags, int startId){

		Notification.Builder bldr=new Notification.Builder(this)
				.setContentTitle("Streaming device screen")
				.setSmallIcon(R.drawable.ic_videocam)
				.setPriority(Notification.PRIORITY_MIN)
				.setOngoing(true);
		if(Build.VERSION.SDK_INT>=Build.VERSION_CODES.O){
			NotificationChannel ch=new NotificationChannel("service", "Foreground service", NotificationManager.IMPORTANCE_MIN);
			bldr.setChannelId(ch.getId());
			((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(ch);
		}
		Notification n=bldr.build();
		startForeground(ID_NOTIFICATION, n);
		projectionData=intent.getParcelableExtra("result_data");
		projectionManager=(MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
		instance=this;

		startServer();
		return START_NOT_STICKY;
	}

	@Override
	public void onCreate(){
		super.onCreate();
		encoderThread.start();
	}

	@Override
	public void onDestroy(){
		super.onDestroy();
		stopForeground(true);
		encoderThread.quit();
		instance=null;
		codecReleased=true;
		if(codec!=null)
			codec.release();
		if(surface!=null)
			surface.release();
		if(virtualDisplay!=null)
			virtualDisplay.release();
		if(projection!=null)
			projection.stop();
		if(serverSocket!=null){
			try{serverSocket.close();}catch(Exception checkedExceptionsAreStupid){}
		}
	}

	public static boolean isRunning(){
		return instance!=null;
	}

	private void startProjection(){
		projection=projectionManager.getMediaProjection(Activity.RESULT_OK, projectionData);
		if(projection==null){
			Log.e(TAG, "Projection is null");
			stopSelf();
			return;
		}
		Display display=((WindowManager)getSystemService(WINDOW_SERVICE)).getDefaultDisplay();
		Point size=new Point();
		display.getRealSize(size);
		float scaling=Math.min(1f, 720f/Math.min(size.x, size.y));
		format=MediaFormat.createVideoFormat("video/avc", Math.round(size.x*scaling), Math.round(size.y*scaling));
		Log.i(TAG, "format: "+format);
		format.setInteger(MediaFormat.KEY_BIT_RATE, 12000000);
		format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
		format.setFloat(MediaFormat.KEY_FRAME_RATE, display.getRefreshRate());
		format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
		Log.i(TAG, "display refresh rate: "+display.getRefreshRate());
		try{
			codec=MediaCodec.createEncoderByType("video/avc");
			codecCallback=new MediaCodec.Callback(){
				@Override
				public void onInputBufferAvailable(MediaCodec codec, int index){
					//Log.v(TAG, "input buffer available");
				}

				@Override
				public void onOutputBufferAvailable(MediaCodec codec, int index, MediaCodec.BufferInfo info){
					if(codecReleased)
						return;
					try{
						ByteBuffer buffer=codec.getOutputBuffer(index);
						//Log.d(TAG, "output buffer length "+info.size+" flags "+info.flags);
						EncodedBuffer buf;
						synchronized(emptyBuffers){
							if(emptyBuffers.size()==0){
								buf=new EncodedBuffer();
								buf.data=new byte[2048000];
							}else{
								buf=emptyBuffers.remove(emptyBuffers.size()-1);
							}
						}
						buf.length=info.size;
						buf.flags=0;
						buffer.position(info.offset);
						buffer.get(buf.data, 0, info.size);
						buffersToSend.add(buf);
						codec.releaseOutputBuffer(index, false);
					}catch(IllegalStateException ignore){}
				}

				@Override
				public void onError(MediaCodec codec, MediaCodec.CodecException e){
					Log.e(TAG, "codec error: "+e+" recoverable "+e.isRecoverable());
				}

				@Override
				public void onOutputFormatChanged(MediaCodec codec, MediaFormat format){
					ByteBuffer[] bufs={format.getByteBuffer("csd-0"), format.getByteBuffer("csd-1")};
					for(ByteBuffer buffer:bufs){
						EncodedBuffer buf;
						synchronized(emptyBuffers){
							if(emptyBuffers.size()==0){
								buf=new EncodedBuffer();
								buf.data=new byte[2048000];
							}else{
								buf=emptyBuffers.remove(emptyBuffers.size()-1);
							}
						}
						buf.length=buffer.limit();
						buf.flags=1;
						buffer.position(0);
						buffer.get(buf.data, 0, buffer.limit());
						buffersToSend.add(buf);
						Log.d(TAG, "Sending codec specific data");
					}
				}
			};
			codec.setCallback(codecCallback);
			codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
			surface=codec.createInputSurface();
			virtualDisplay=projection.createVirtualDisplay("ScreenProjection", Math.round(size.x*scaling), Math.round(size.y*scaling), Math.round(getResources().getDisplayMetrics().xdpi*scaling), DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, new Handler(encoderThread.getLooper()));
			((DisplayManager)getSystemService(DISPLAY_SERVICE)).registerDisplayListener(this, new Handler(Looper.getMainLooper()));
			codec.start();
		}catch(Exception x){
			Log.w(TAG, x);
		}
	}

	private void startServer(){
		new Thread(new Runnable(){
			@Override
			public void run(){
				try{
					serverSocket=new ServerSocket(5050);
					serverSocket.setSoTimeout(10000);
					//while(true){
						currentClientSocket=serverSocket.accept();
					Log.i(TAG, "accepted a connection");
					currentClientSocket.setTcpNoDelay(true);
					ByteArrayOutputStream obuf=new ByteArrayOutputStream();
					DataOutputStream out=new DataOutputStream(obuf);
						currentClientStream=new DataOutputStream(currentClientSocket.getOutputStream());
						InputStream in=currentClientSocket.getInputStream();
					startProjection();
					in.read();
					try{
						while(true){
							EncodedBuffer buf=buffersToSend.take();
							obuf.reset();
							out.writeInt(buf.length);
							out.write(buf.flags);
							if(buf.length>0)
								out.write(buf.data, 0, buf.length);
							obuf.writeTo(currentClientStream);
							synchronized(emptyBuffers){
								emptyBuffers.add(buf);
							}
						}
					}catch(Exception x){
						Log.w(TAG, x);
					}
						currentClientSocket.close();
					//}
				}catch(Exception x){
					Log.e(TAG, "error in server", x);
				}finally{
					try{
						serverSocket.close();
					}catch(IOException ignore){

					}
					stopSelf();
				}
			}
		}).start();
	}

	@Override
	public void onDisplayAdded(int displayId){

	}

	@Override
	public void onDisplayRemoved(int displayId){

	}

	@Override
	public void onDisplayChanged(int displayId){
		Log.i(TAG, "onDisplayChanged "+displayId);
		Display display=((WindowManager)getSystemService(WINDOW_SERVICE)).getDefaultDisplay();
		if(display.getDisplayId()!=displayId)
			return;
		codecReleased=true;
		for(int i=0;i<10;i++){
			try{
				codec.reset();
				break;
			}catch(Exception x){
				Log.w(TAG, x);
			}
		}
		Point size=new Point();
		display.getRealSize(size);
		float scaling=Math.min(1f, 720f/Math.min(size.x, size.y));
		format.setInteger(MediaFormat.KEY_WIDTH, Math.round(size.x*scaling));
		format.setInteger(MediaFormat.KEY_HEIGHT, Math.round(size.y*scaling));
		codec.setCallback(codecCallback);
		codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
		virtualDisplay.resize(Math.round(size.x*scaling), Math.round(size.y*scaling), Math.round(getResources().getDisplayMetrics().xdpi*scaling));
		virtualDisplay.setSurface(surface=codec.createInputSurface());
		codecReleased=false;
		codec.start();
	}

	private static class EncodedBuffer{
		byte[] data;
		int length;
		int flags;
	}
}
