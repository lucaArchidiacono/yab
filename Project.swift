import ProjectDescription

let project = Project(
    name: "yab",
    targets: [
        .target(
            name: "yab",
            destinations: .iOS,
            product: .app,
            bundleId: "ch.archiluc.yab",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(
                with: [
                    "UILaunchScreen": [
                        "UIColorName": "",
                        "UIImageName": "",
                    ],
                ]
            ),
            buildableFolders: [
                "yab/Sources",
                "yab/Resources",
            ],
            dependencies: []
        ),
        .target(
            name: "yabTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "ch.archiluc.yabTests",
            infoPlist: .default,
            buildableFolders: [
                "yab/Tests"
            ],
            dependencies: [.target(name: "yab")]
        ),
    ]
)
