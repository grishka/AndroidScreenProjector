package me.grishka.screenprojector;

import android.app.Activity;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.Toast;

public class MainActivity extends Activity{

	private Button startBtn;
	private MediaProjectionManager projectionManager;

	private int resultCode;
	private Intent resultData;

	private static final int PROJECTION_RESULT=101;

	@Override
	protected void onCreate(Bundle savedInstanceState){
		super.onCreate(savedInstanceState);

		projectionManager=(MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
		setupMediaProjection();
	}

	private void setupMediaProjection(){
		if(resultData==null){
			startActivityForResult(projectionManager.createScreenCaptureIntent(), PROJECTION_RESULT);
		}else{
			startProjectionService();
		}
	}

	@Override
	protected void onActivityResult(int requestCode, int resultCode, Intent data){
		if(requestCode==PROJECTION_RESULT){
			if(resultCode!=RESULT_OK){
				Toast.makeText(this, "Permission denied :(", Toast.LENGTH_SHORT).show();
				finish();
				return;
			}
			this.resultCode=resultCode;
			resultData=data;
			startProjectionService();
		}
	}

	private void startProjectionService(){
		Intent intent=new Intent(this, ProjectionService.class);
		intent.putExtra("result_data", resultData);
		startService(intent);
		finish();
	}
}
