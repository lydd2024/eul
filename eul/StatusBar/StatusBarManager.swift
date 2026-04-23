//
//  StatusBarManager.swift
//  eul
//
//  Created by Gao Sun on 2020/8/22.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Combine
import SwiftUI

class StatusBarManager {
    static let shared = StatusBarManager()

    @ObservedObject var preferenceStore = SharedStore.preference
    @ObservedObject var componentsStore = SharedStore.components
    private var activeCancellable: AnyCancellable?
    private var displayCancellable: AnyCancellable?
    private var showComponentsCancellable: AnyCancellable?
    private var showIconCancellable: AnyCancellable?
    private var fontDesignCancellable: AnyCancellable?
    private var appearanceModeCancellable: AnyCancellable?
    private let item = StatusBarItem()

    init() {
        // w/o the delay items will have a chance of not appearing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.subscribe()
        }
    }

    func checkVisibilityIfNeeded() {
        item.checkVisibilityIfNeeded()
    }

    func subscribe() {
        // TO-DO: refactor
        activeCancellable = SharedStore.components.$activeComponents.sink { [self] components in
            DispatchQueue.main.async {
                self.render(components: components)
            }
        }
        displayCancellable = preferenceStore.$textDisplay.sink { _ in
            DispatchQueue.main.async {
                self.refresh()
            }
        }
        showComponentsCancellable = SharedStore.components.$showComponents.sink { _ in
            DispatchQueue.main.async {
                self.refresh()
            }
        }
        showIconCancellable = preferenceStore.$showIcon.sink { _ in
            DispatchQueue.main.async {
                self.refresh()
            }
        }
        fontDesignCancellable = preferenceStore.$fontDesign.sink { _ in
            DispatchQueue.main.async {
                self.refresh()
            }
        }
        // Disable in Catalina to avoid protential crash
        if #available(OSX 11, *) {
            appearanceModeCancellable = preferenceStore.$appearanceMode.sink { value in
                DispatchQueue.main.async {
                    self.item.setAppearance(value.nsAppearance)
                }
            }
        }
    }

    func refresh() {
        DispatchQueue.main.async {
            self.item.refresh()
        }
    }

    func render(components _: [EulComponent]) {
        // Defer state change to avoid modifying state during view update
        DispatchQueue.main.async {
            self.item.isVisible = false
            DispatchQueue.main.async {
                self.item.isVisible = true
            }
        }
    }
}
