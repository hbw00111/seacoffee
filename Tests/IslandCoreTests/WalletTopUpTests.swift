import Foundation
import IslandCore

final class WalletTopUpTests {
    func rebasing() {
        // A top-up: the balance grew, so it becomes the new full ring.
        expectEqual(WalletTopUp.rebasedBaseline(previousBalance: 12.40, currentBalance: 112.40, baseline: 100), 112.40)
        // Spending, no change, or sub-cent noise never moves the baseline.
        expectNil(WalletTopUp.rebasedBaseline(previousBalance: 80, currentBalance: 79.2, baseline: 100))
        expectNil(WalletTopUp.rebasedBaseline(previousBalance: 80, currentBalance: 80, baseline: 100))
        expectNil(WalletTopUp.rebasedBaseline(previousBalance: 80, currentBalance: 80.004, baseline: 100))
        // Topped up to exactly the baseline already set: nothing to change.
        expectNil(WalletTopUp.rebasedBaseline(previousBalance: 30, currentBalance: 100, baseline: 100))
        // The first scan has nothing to compare against.
        expectNil(WalletTopUp.rebasedBaseline(previousBalance: nil, currentBalance: 50, baseline: 100))
        expectNil(WalletTopUp.rebasedBaseline(previousBalance: 50, currentBalance: nil, baseline: 100))
        expectNil(WalletTopUp.rebasedBaseline(previousBalance: 50, currentBalance: .infinity, baseline: 100))
        // A top-up that leaves the balance below the old baseline still resets the ring to full.
        expectEqual(WalletTopUp.rebasedBaseline(previousBalance: 5, currentBalance: 55, baseline: 100), 55)
    }

    func snapshotRebase() throws {
        let usage = try UsageDecoder.sub2API(Data(#"{"balance":150}"#.utf8), baseline: 100)
        expectEqual(usage.hasWallet, true)
        expectEqual(usage.quotas.first?.percent, 100, "above the old baseline the ring clamps to full")
        let rebased = usage.rebasingWallet(to: 150)
        expectEqual(rebased.quotas.first?.limit, 150)
        expectEqual(rebased.quotas.first?.remaining, 150)
        expectEqual(rebased.balance, 150)
        expectEqual(rebased.fetchedAt, usage.fetchedAt)
        // Key and subscription quotas carry their own totals and are not wallets.
        let keyed = try UsageDecoder.sub2API(Data(#"{"balance":40,"quota":{"limit":200,"remaining":120}}"#.utf8), baseline: 100)
        expectEqual(keyed.hasWallet, false)
        expectEqual(keyed.rebasingWallet(to: 40).quotas.first?.limit, 200)
    }
}
