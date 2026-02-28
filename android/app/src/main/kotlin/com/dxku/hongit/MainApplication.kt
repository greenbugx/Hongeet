package com.dxku.hongit

import android.app.Application
import com.dxku.hongit.widget.MusicWidgetManager

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        MusicWidgetManager.initialize(this)
    }
}
