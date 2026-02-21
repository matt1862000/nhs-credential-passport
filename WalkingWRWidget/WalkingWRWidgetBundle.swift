//
//  WalkingWRWidgetBundle.swift
//  WalkingWRWidget
//

import WidgetKit
import SwiftUI

@main
struct WalkingWRWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            WalkLiveActivity()
            WaitTimeLiveActivity()
        }
    }
}
