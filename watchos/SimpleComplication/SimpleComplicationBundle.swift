//
//  SimpleComplicationBundle.swift
//  SimpleComplication
//
//  Created by Mac on 5/4/26.
//

import WidgetKit
import SwiftUI

@main
struct SimpleComplicationBundle: WidgetBundle {
    var body: some Widget {
        SimpleComplication()
        SimpleComplicationControl()
    }
}
