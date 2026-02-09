package com.dxku.hongit

import android.os.Bundle
import com.dxku.hongit.backend.MainService
//import io.flutter.embedding.android.FlutterActivity
import com.ryanheise.audioservice.AudioServiceActivity;

class MainActivity : AudioServiceActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MainService.start(this)
    }

    override fun onDestroy() {
        super.onDestroy()
        // Android may kill background audio here, so stop the server
       // MainService.stop()
    }
}
