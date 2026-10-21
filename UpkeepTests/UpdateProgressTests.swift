import Foundation
import XCTest

@testable import Upkeep

@MainActor
final class UpdateProgressTests: XCTestCase {
    func testEveryReportedStatusMapsToItsStage() {
        let expectations: [String: UpdateProgress.Stage] = [
            "正在更新…": .preparing,
            "正在检查更新…": .preparing,
            "正在准备更新…": .preparing,
            "正在退出…": .preparing,
            "正在下载…": .downloading,
            "连接中断，正在重试（2/3）…": .downloading,
            "正在校验…": .verifying,
            "正在验证安装包…": .verifying,
            "正在验证更新…": .verifying,
            "下载完成，等待安装…": .installing,
            "正在解压…": .installing,
            "正在解压更新…": .installing,
            "正在安装…": .installing,
            "正在处理更新…": .installing,
            "正在连接安装助手…": .installing,
            "正在等待管理员授权…": .installing,
            "正在完成…": .finishing,
            "正在重新打开…": .finishing,
        ]
        for (status, stage) in expectations {
            XCTAssertEqual(UpdateProgress.indeterminate(status).stage, stage, status)
        }
    }

    func testOverallFractionMovesForwardThroughStages() {
        let sequence = [
            UpdateProgress.indeterminate("正在更新…"),
            UpdateProgress(fractionCompleted: 0, status: "正在下载…"),
            UpdateProgress(fractionCompleted: 0.5, status: "正在下载…"),
            UpdateProgress(fractionCompleted: 1, status: "正在下载…"),
            .indeterminate("正在校验…"),
            .indeterminate("正在解压…"),
            .indeterminate("正在安装…"),
            UpdateProgress(fractionCompleted: 1, status: "正在完成…"),
        ]
        let fractions = sequence.map(\.overallFraction)
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(sequence[2].overallFraction, 0.42, accuracy: 0.0001)
        // Homebrew caps downloads at 90% and reports installs at 92%.
        XCTAssertLessThan(
            UpdateProgress(fractionCompleted: 0.9, status: "正在下载…").overallFraction,
            UpdateProgress(fractionCompleted: 0.92, status: "正在安装…").overallFraction)
    }

    func testRetriedDownloadDoesNotMoveTheBarBack() {
        let state = ApplicationUpdateState()
        state.begin()
        XCTAssertEqual(state.overallFraction, 0)
        state.report(UpdateProgress(fractionCompleted: 0.8, status: "正在下载…"))
        let reached = state.overallFraction
        state.report(.indeterminate("连接中断，正在重试（2/3）…"))
        state.report(UpdateProgress(fractionCompleted: 0.1, status: "正在下载…"))
        XCTAssertEqual(state.overallFraction, reached)
        state.report(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
        XCTAssertEqual(state.overallFraction, 1)

        state.finish()
        state.begin()
        XCTAssertEqual(state.overallFraction, 0)
    }

    func testRemainingTimeNeedsAStableRateAndRestartsWithTheDownload() throws {
        var estimator = TransferRateEstimator()
        let megabyte: Int64 = 1_000_000
        estimator.record(bytes: 0, at: 0)
        estimator.record(bytes: 2 * megabyte, at: 0.1)  // Folded into the next sample.
        XCTAssertNil(estimator.remainingSeconds(completed: 2 * megabyte, total: 100 * megabyte))

        for second in 1...3 {
            estimator.record(bytes: Int64(second) * 10 * megabyte, at: TimeInterval(second))
        }
        let remaining = try XCTUnwrap(
            estimator.remainingSeconds(completed: 30 * megabyte, total: 100 * megabyte))
        XCTAssertEqual(remaining, 7, accuracy: 0.01)

        estimator.record(bytes: megabyte, at: 4)
        XCTAssertNil(estimator.remainingSeconds(completed: megabyte, total: 100 * megabyte))
    }

    func testRemainingTimeIsRoundedForReading() {
        XCTAssertEqual(AppUpdateProgressView.remainingText(4), "剩余几秒")
        XCTAssertEqual(AppUpdateProgressView.remainingText(23), "剩余约 25 秒")
        XCTAssertEqual(AppUpdateProgressView.remainingText(130), "剩余约 2 分钟")
    }

    func testDownloadsReportTheirByteCounts() {
        let progress = UpdateProgress(
            fractionCompleted: 0.25, status: "正在下载…", completedBytes: 25, totalBytes: 100)
        XCTAssertEqual(progress.stage, .downloading)
        XCTAssertEqual(progress.completedBytes, 25)
        XCTAssertEqual(progress.totalBytes, 100)
        XCTAssertEqual(progress.percentText, "25%")
    }
}
