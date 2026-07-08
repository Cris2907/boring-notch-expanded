import AppKit
import XCTest
@testable import boringNotch

@MainActor
final class NotchWindowKeyboardFocusTests: XCTestCase {
    func testBothPanelImplementationsRemainNonactivatingAndBecomeKeyOnlyWhenNeeded() {
        let standardWindow = makeStandardWindow()
        let skyLightWindow = makeSkyLightWindow()
        defer {
            standardWindow.close()
            skyLightWindow.close()
        }

        for window in [standardWindow, skyLightWindow] {
            XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(window.canBecomeKey)
            XCTAssertFalse(window.canBecomeMain)
            XCTAssertTrue(window.becomesKeyOnlyIfNeeded)
        }
    }

    func testAppKitControlsDeclareWhetherTheyNeedPanelKeyStatus() {
        XCTAssertTrue(NSTextField().needsPanelToBecomeKey)
        XCTAssertTrue(NSTextView().needsPanelToBecomeKey)
        XCTAssertFalse(NSButton().needsPanelToBecomeKey)
    }

    func testClosingNotchClearsKeyboardInteractionWithoutHidingWindow() {
        let viewModel = BoringViewModel()
        let window = makeStandardWindow()
        let inputView = KeyboardInputTestView()
        defer { window.close() }

        window.bindKeyboardFocus(to: viewModel)
        window.contentView = inputView
        window.orderFrontRegardless()
        viewModel.open()
        window.makeKey()
        XCTAssertTrue(window.makeFirstResponder(inputView))
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(viewModel.isKeyboardInteractionActive)

        viewModel.close()

        XCTAssertFalse(viewModel.isKeyboardInteractionActive)
        XCTAssertTrue(window.firstResponder === window)
        XCTAssertTrue(window.isVisible)
        print("Notch panel remains key after clearing first responder: \(window.isKeyWindow)")
    }

    func testKeyTransitionMovesKeyboardInteractionBetweenDisplayWindows() {
        let firstViewModel = BoringViewModel(screenUUID: "first-display")
        let secondViewModel = BoringViewModel(screenUUID: "second-display")
        let firstWindow = makeStandardWindow()
        let secondWindow = makeSkyLightWindow()
        let firstInput = KeyboardInputTestView()
        let secondInput = KeyboardInputTestView()
        defer {
            firstWindow.close()
            secondWindow.close()
        }

        firstWindow.bindKeyboardFocus(to: firstViewModel)
        secondWindow.bindKeyboardFocus(to: secondViewModel)
        firstWindow.contentView = firstInput
        secondWindow.contentView = secondInput
        firstWindow.orderFrontRegardless()
        secondWindow.orderFrontRegardless()
        firstViewModel.open()
        secondViewModel.open()

        firstWindow.makeKey()
        XCTAssertTrue(firstWindow.makeFirstResponder(firstInput))
        XCTAssertTrue(firstViewModel.isKeyboardInteractionActive)
        XCTAssertFalse(secondViewModel.isKeyboardInteractionActive)

        secondWindow.makeKey()
        XCTAssertTrue(secondWindow.makeFirstResponder(secondInput))

        XCTAssertFalse(firstViewModel.isKeyboardInteractionActive)
        XCTAssertTrue(secondViewModel.isKeyboardInteractionActive)
    }

    private func makeStandardWindow() -> BoringNotchWindow {
        BoringNotchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: notchPanelStyleMask,
            backing: .buffered,
            defer: false
        )
    }

    private func makeSkyLightWindow() -> BoringNotchSkyLightWindow {
        BoringNotchSkyLightWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: notchPanelStyleMask,
            backing: .buffered,
            defer: false
        )
    }

    private var notchPanelStyleMask: NSWindow.StyleMask {
        [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
    }
}

@MainActor
private final class KeyboardInputTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}
