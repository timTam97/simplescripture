//
//  SimpleScriptureAppDelegate.swift
//  SimpleScripture
//
//  Reached through `@UIApplicationDelegateAdaptor`; `@main` is on
//  `SimpleScriptureApp`. It owns what is genuinely delegate-shaped:
//  `BGTaskScheduler.register` (must be called before `didFinishLaunching`
//  returns), starting iCloud history sync once per process, the long-lived
//  models, and the scene-orientation hook. URLs arrive via `onOpenURL` and are
//  routed by `AppSession.open(_:)`.
//
//  Copyright (C) 2008-2010 CrossWire Bible Society
//
//  This program is free software; you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation; either version 2 of the License, or (at your option) any later
//  version.
//

import UIKit

@MainActor
final class SimpleScriptureAppDelegate: NSObject, UIApplicationDelegate {

    let session: AppSession
    let launchCoordinator = LaunchCoordinator()
    private(set) lazy var readingWorkspace = ReadingWorkspaceModel(
        session: session
    )

    private let historyStore: HistoryStore
    private let searchIndexBackgroundManager: SearchIndexBackgroundManager

    override init() {
        let historyStore = HistoryStore()
        let searchIndexBackgroundManager = SearchIndexBackgroundManager()
        self.historyStore = historyStore
        self.searchIndexBackgroundManager = searchIndexBackgroundManager
        self.session = AppSession(
            library: LibraryModel(historyStore: historyStore),
            search: SearchModel(
                indexBuildStarted: {
                    searchIndexBackgroundManager.beginForegroundBuild(module: $0)
                },
                indexBuildFinished: {
                    searchIndexBackgroundManager.finishForegroundBuild(module: $0)
                }
            )
        )
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Must happen before this method returns, which is the whole reason an
        // app delegate is still here.
        _ = searchIndexBackgroundManager.register()
        searchIndexBackgroundManager.resumePendingBuildIfNeeded()
        historyStore.startCloudSync()
        session.start()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        // The ONLY reason a scene delegate still exists: the rotation-lock
        // preference has to be reported through
        // `supportedInterfaceOrientations(for:)`, and SwiftUI has no equivalent
        // modifier on iOS.
        configuration.delegateClass = SimpleScriptureSceneOrientationDelegate.self
        return configuration
    }
}

/// Reports the rotation-lock preference to the window scene.
///
/// `supportedInterfaceOrientations(for:)` (iOS 27) is the scene-scoped
/// replacement for the deprecated
/// `application(_:supportedInterfaceOrientationsFor:)`; the returned mask
/// overrides the Info.plist `UISupportedInterfaceOrientations` for this scene.
///
/// The mask comes from `RotationLock`: unlocked allows all but upside-down on
/// iPhone (all on iPad), and the two locked states pin to their orientation.
final class SimpleScriptureSceneOrientationDelegate: UIResponder,
                                                     UIWindowSceneDelegate {
    func supportedInterfaceOrientations(
        for windowScene: UIWindowScene
    ) -> UIInterfaceOrientationMask {
        let isPad = UIDevice.current.userInterfaceIdiom != .phone
        let lock = RotationLock(
            rawValue: UserDefaults.standard.integer(
                forKey: Defaults.rotationLockPosition
            )
        ) ?? .unlocked

        switch lock {
        case .unlocked:
            return isPad ? .all : .allButUpsideDown
        case .landscape:
            return .landscape
        case .portrait:
            return isPad ? [.portrait, .portraitUpsideDown] : .portrait
        }
    }
}
