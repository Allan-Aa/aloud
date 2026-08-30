import XCTest
@testable import Aloud

@MainActor
final class CredentialDraftStateTests: XCTestCase {
    func testOnePasswordOperationIsSpecificVisibleAndCannotDoubleStart() {
        let state = CredentialDraftState()

        XCTAssertTrue(state.begin(.onePasswordImport, for: .minimax))
        XCTAssertFalse(state.begin(.onePasswordImport, for: .minimax))
        XCTAssertEqual(state.status[.minimax], .working(.onePasswordImport))
        XCTAssertEqual(state.status[.minimax]?.message(.zh), "正在从 1Password 读取…")
        XCTAssertNil(state.status[.openAI])
    }

    func testLateSuccessAfterRestoreCannotReviveCancelledOperationState() async throws {
        let state = CredentialDraftState()
        await state.load { provider in
            provider == .openAI
                ? .available(.init(providerID: provider, revision: UUID(), secret: Data()))
                : .missing
        }
        state.setDraft("unfinished", for: .openAI)
        let operation = try XCTUnwrap(state.beginOperation(.manualSave, for: .openAI))

        state.restoreLoadedStatus(for: .openAI)
        state.completeSave(
            for: .openAI,
            result: .success(()),
            successSource: .manual,
            operationToken: operation
        )

        XCTAssertEqual(state.status[.openAI], .configured)
        XCTAssertEqual(state.draft(for: .openAI), "unfinished")
        XCTAssertNil(state.recentSuccessSource[.openAI])
    }

    func testCredentialSuccessSourceIsProviderScopedAndClearedBeforeNextOperation() {
        let state = CredentialDraftState()
        state.completeSave(for: .minimax, result: .success(()), successSource: .onePassword)
        XCTAssertEqual(state.recentSuccessSource[.minimax], .onePassword)
        XCTAssertNil(state.recentSuccessSource[.openAI])

        XCTAssertTrue(state.begin(.onePasswordImport, for: .minimax))
        XCTAssertNil(state.recentSuccessSource[.minimax])
        state.restoreLoadedStatus(for: .minimax)
        XCTAssertNil(state.recentSuccessSource[.minimax])
    }

    func testFailureAfterNewOperationNeverRestoresOldSuccessSource() {
        let state = CredentialDraftState()
        state.completeSave(for: .openAI, result: .success(()), successSource: .manual)
        XCTAssertTrue(state.begin(.manualSave, for: .openAI))
        state.completeSave(for: .openAI, result: .failure(.keychainUnavailable))
        XCTAssertNil(state.recentSuccessSource[.openAI])
    }

    func testLoadCannotOverwriteProviderWorkStartedWhileItsReadIsPending() async {
        let state = CredentialDraftState()
        let barrier = CredentialDraftLoadBarrier()
        let load = Task { @MainActor in
            await state.load { provider in
                if provider == .minimax { await barrier.enterAndWait() }
                return .missing
            }
        }

        await barrier.waitUntilEntered()
        XCTAssertTrue(state.begin(.onePasswordImport, for: .minimax))
        await barrier.release()
        await load.value

        XCTAssertEqual(state.status[.minimax], .working(.onePasswordImport))
        XCTAssertFalse(state.begin(.onePasswordImport, for: .minimax))
        XCTAssertEqual(state.status[.openAI], .missing)
    }

    func testCancellationCanRestoreLastLoadedStatusWithoutFailureBanner() async {
        let state = CredentialDraftState()
        await state.load { provider in
            provider == .minimax
                ? .available(.init(providerID: provider, revision: UUID(), secret: Data()))
                : .missing
        }
        XCTAssertTrue(state.begin(.onePasswordImport, for: .minimax))

        state.restoreLoadedStatus(for: .minimax)

        XCTAssertEqual(state.status[.minimax], .configured)
        XCTAssertFalse(state.status.values.contains { if case .saveFailed = $0 { return true }; return false })
        XCTAssertEqual(state.status[.openAI], .missing)
    }

    func testStaleLoadCannotOverwriteCompletedImportSuccessOrRecoverySnapshot() async {
        let state = CredentialDraftState()
        let barrier = CredentialDraftLoadBarrier()
        let load = Task { @MainActor in
            await state.load { provider in
                if provider == .minimax { await barrier.enterAndWait() }
                return .missing
            }
        }

        await barrier.waitUntilEntered()
        XCTAssertTrue(state.begin(.onePasswordImport, for: .minimax))
        state.completeSave(for: .minimax, result: .success(()))
        await barrier.release()
        await load.value

        XCTAssertEqual(state.status[.minimax], .configured)
        XCTAssertTrue(state.begin(.onePasswordImport, for: .minimax))
        state.restoreLoadedStatus(for: .minimax)
        XCTAssertEqual(state.status[.minimax], .configured)
    }

    func testStaleLoadCannotOverwriteCompletedManualFailureOrLoadedSnapshot() async {
        let state = CredentialDraftState()
        await state.load { provider in
            provider == .minimax
                ? .available(.init(providerID: provider, revision: UUID(), secret: Data()))
                : .missing
        }
        let barrier = CredentialDraftLoadBarrier()
        let load = Task { @MainActor in
            await state.load { provider in
                if provider == .minimax { await barrier.enterAndWait() }
                return .missing
            }
        }

        await barrier.waitUntilEntered()
        XCTAssertTrue(state.begin(.manualSave, for: .minimax))
        state.completeSave(for: .minimax, result: .failure(.keychainUnavailable))
        await barrier.release()
        await load.value

        XCTAssertEqual(state.status[.minimax], .saveFailed(.keychainUnavailable))
        XCTAssertTrue(state.begin(.manualSave, for: .minimax))
        state.restoreLoadedStatus(for: .minimax)
        XCTAssertEqual(state.status[.minimax], .configured)
    }

    func testLaterStartedLoadWinsWhenConcurrentLoadsFinishOutOfOrder() async {
        let state = CredentialDraftState()
        let firstBarrier = CredentialDraftLoadBarrier()
        let secondBarrier = CredentialDraftLoadBarrier()
        let first = Task { @MainActor in
            await state.load { provider in
                if provider == .minimax { await firstBarrier.enterAndWait() }
                return .missing
            }
        }
        await firstBarrier.waitUntilEntered()
        let second = Task { @MainActor in
            await state.load { provider in
                if provider == .minimax { await secondBarrier.enterAndWait() }
                return provider == .minimax
                    ? .available(.init(providerID: provider, revision: UUID(), secret: Data()))
                    : .missing
            }
        }
        await secondBarrier.waitUntilEntered()

        await secondBarrier.release()
        await second.value
        await firstBarrier.release()
        await first.value

        XCTAssertEqual(state.status[.minimax], .configured)
    }

    func testConcurrentLoadAndProviderScopedSaveResultsStayOnMainActor() async throws {
        let state = CredentialDraftState()
        state.setDraft("a", for: .minimax); state.setDraft("b", for: .openAI); state.setDraft("c", for: .gemini)
        await state.load { provider in provider == .openAI ? .available(.init(providerID: provider, revision: UUID(), secret: Data())) : .missing }
        XCTAssertEqual(state.status[.openAI], .configured)
        state.completeSave(for: .openAI, result: .success(()))
        XCTAssertEqual(state.draft(for: .openAI), "")
        XCTAssertEqual(state.draft(for: .minimax), "a")
        state.completeSave(for: .gemini, result: .failure(.keychainUnavailable))
        XCTAssertEqual(state.draft(for: .gemini), "c")
    }

    func testProviderScopedStatusAndDraftNeverBleedWhenSwitchingCards() async {
        let state = CredentialDraftState()
        await state.load { provider in
            switch provider { case .minimax: .available(.init(providerID: provider, revision: UUID(), secret: Data())); case .openAI: .blocked(.nonV1Item); default: .missing }
        }
        state.setDraft("openai-draft", for: .openAI)
        state.beginSave(for: .gemini)
        XCTAssertEqual(state.status[.minimax], .configured)
        XCTAssertEqual(state.status[.openAI], .blocked(.nonV1Item))
        XCTAssertEqual(state.status[.gemini], .working(.manualSave))
        XCTAssertEqual(state.draft(for: .openAI), "openai-draft")
        XCTAssertEqual(state.draft(for: .minimax), "")
        state.completeSave(for: .gemini, result: .success(()))
        XCTAssertEqual(state.status[.gemini], .configured)
        XCTAssertEqual(state.status[.openAI], .blocked(.nonV1Item))
        XCTAssertEqual(state.draft(for: .openAI), "openai-draft")
    }
    func testClosedFailureReasonsHaveProviderSafeBilingualMessages() {
        XCTAssertEqual(ProviderCredentialUIStatus.saveFailed(.keychainUnavailable).message(.zh), "钥匙串暂不可用，请重试")
        XCTAssertEqual(ProviderCredentialUIStatus.saveFailed(.keychainUnavailable).message(.en), "Keychain is unavailable. Try again.")
        XCTAssertEqual(ProviderCredentialUIStatus.saveFailed(.rejectedInput).message(.zh), "请输入有效的 API Key")
        XCTAssertEqual(ProviderCredentialUIStatus.saveFailed(.rejectedInput).message(.en), "Enter a valid API key.")
    }

    func testEmptyManualInputIsRejectedForEveryCloudProviderWithoutStatusBleed() {
        for provider in [ProviderID.minimax, .openAI, .gemini] {
            let state = CredentialDraftState()
            state.setDraft("   ", for: provider)
            state.completeSave(for: provider, result: .failure(.classify(CredentialEnvelopeError.empty)))
            XCTAssertEqual(state.status[provider], .saveFailed(.rejectedInput))
            XCTAssertEqual(ProviderCredentialUIStatus.saveFailed(.rejectedInput).message(.en), "Enter a valid API key.")
        }
    }

    func testOnePasswordFailuresUseSafeSpecificMessages() {
        XCTAssertEqual(ProviderCredentialUIFailure.classify(OnePasswordPipeError.launchFailed), .onePasswordUnavailable)
        XCTAssertEqual(ProviderCredentialUIFailure.classify(OnePasswordPipeError.malformedOutput), .onePasswordOutputInvalid)
        XCTAssertEqual(ProviderCredentialUIFailure.classify(OnePasswordPipeError.timedOut), .onePasswordTimedOut)
        XCTAssertEqual(ProviderCredentialUIFailure.classify(OnePasswordPipeError.nonZeroExit), .onePasswordImportFailed)
        XCTAssertNil(ProviderCredentialUIFailure.classify(OnePasswordPipeError.cancelled, viewIsDisappearing: true))
    }
}

private actor CredentialDraftLoadBarrier {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
