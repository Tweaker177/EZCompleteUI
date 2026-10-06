# Client patch: handle the new "spins" outcome from claim-daily-coins

The hourly/daily claim is now a 50/50 roll between coins and free spins
server-side. Your current `claimDailyCoins` success branch only reads
`coins_added` and always calls `showCoinCelebration:newBalance:`, so a
spins-outcome response needs a branch or it'll show "+0 coins" / the wrong
balance.

In `claimDailyCoins`, inside the `if (httpResponse.statusCode == 200 &&
[json[@"success"] boolValue])` block, replace the body with:

```objc
NSString *rewardType = jsonString(json, @"reward_type");
self.nextDailyClaimDate    = dateFromISO8601String(jsonString(json, @"next_claim_at"));
self.isDailyCoinsAvailable = NO;
[self scheduleDailyCoinsReadyReminderForDate:self.nextDailyClaimDate requestPermissionIfNeeded:YES];
[self updateDailyCoinsButtonState];

if ([rewardType isEqualToString:@"spins"]) {
    NSInteger spinsAdded = jsonInteger(json, @"spins_added");
    [self showFreeSpinsCelebration:spinsAdded];
} else {
    NSInteger coinsAdded = jsonInteger(json, @"coins_added");
    NSInteger newBalance = jsonInteger(json, @"balance");
    [[EZEntitlementManager shared] applyKnownBalance:newBalance];
    [self showCoinCelebration:coinsAdded newBalance:newBalance];
}

[[NSNotificationCenter defaultCenter] postNotificationName:@"EZSubscriptionUpdated" object:nil];
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self refreshBalance];
});
```

Then add a small celebration method near `showCoinCelebration:newBalance:`
(reuse whatever that one does for layout — this is the minimal version):

```objc
- (void)showFreeSpinsCelebration:(NSInteger)spinsAdded {
    [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.FreeSpinsTitle", @"Daily free spins alert title")
             message:[NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Alert.FreeSpinsMessage", @"Daily free spins alert message"), (long)spinsAdded]];
}
```

(`showAlert:message:` already exists elsewhere in this file/your other view
controllers — if `EZCoinStoreViewController` doesn't have one, point it at
whatever your existing alert helper is, or style it like
`presentPitySpinsPopupWithCount:` from the Slots patch for something nicer
than a plain alert.)

Add the two string keys:
- `EZCoinStore.Alert.FreeSpinsTitle` → "🎁 Free Spins!"
- `EZCoinStore.Alert.FreeSpinsMessage` → "You got %ld free spins on Brainrot Slots — head over and give them a pull!"

`jsonString`/`jsonInteger` are the same helpers you already use elsewhere
in this file for the GET status response.
