// BRGamePickerViewController.m
// BrainRotGame
// EZCompleteUI v2.9 — Community Admin Panel
//
// Changes from v2.8:
//   - Added a debug-only admin panel entry point (shield icon, top-left,
//     visible only when the Community tab is active). Tapping it presents
//     BRCommunityAdminViewController inside a UINavigationController.
//     The button is wrapped in #if DEBUG / #endif so it never compiles into
//     App Store or ad-hoc builds. The server-side BR_ADMIN_CODE check is
//     independent and enforced regardless of build type.
//
// Changes from v2.7:
//   - handleCloseTapped now dismisses self.presentingViewController
//     (BrainRotViewController) rather than self (the picker). Dismissing
//     the presenter collapses the whole stack — picker + BrainRotVC — in
//     one animation from the main VC's perspective, rather than two
//     sequential dismissals (picker slides away → BrainRotVC briefly
//     visible → BrainRotVC slides away). After the single dismiss animation
//     the player is back in the main app with no intermediate state.
//     A nil-presenter fallback keeps the old self-dismiss as a safety path
//     if the picker is ever pushed rather than presented modally.
//
// Changes from v2.6:
//   - Tapping a community card now opens the same BRGameResultViewController
//     reveal card used everywhere else (title/premise/thumbnails), instead
//     of a UIAlertController confirmation. The card's primary button reads
//     DOWNLOAD (showing the cost) rather than PLAY, since the game isn't
//     local yet; tapping it triggers the actual network call, and on
//     success the SAME card morphs its button into PLAY — no dismiss, no
//     re-presentation, see BRGameResultViewController v2.0.
//   - presentDownloadConfirmationForCommunityGame: removed (the reveal card
//     itself, with its cost-labeled DOWNLOAD button, now serves as the
//     confirmation step — a separate alert first would be redundant).
//   - performDownloadForCommunityGame:/handleDownloadResponseData:... kept
//     their network logic but now report outcomes via a completion block
//     (BRGameResultDownloadHandler's contract) instead of managing their
//     own spinner UI directly — BRGameResultViewController owns showing
//     "Downloading your game..." and reverting to DOWNLOAD on failure now.
//   - Removed showBlockingSpinnerWithMessage:/hideBlockingSpinner and
//     blockingOverlayView entirely — they existed only for the old
//     confirm-then-download flow and have no remaining callers.
//   - Extracted BRRemoteImageLoader into its own file (BRRemoteImageLoader.h/.m)
//     now that BRGameResultViewController also needs it for the community-
//     preview card's async thumbnail/background loads.
//
// Changes from v2.5:
//   - Added a UISegmentedControl ("My Games" / "Community") below the
//     header. "My Games" is the existing New Game + saved-games grid,
//     unchanged. "Community" shows a paginated public browse list via
//     br-community's list_shared_games action — no sign-in required, since
//     browsing shouldn't be gated behind auth even though
//     downloading/sharing/reporting all are.
//   - New BRCommunitySharedGame model (one row of list_shared_games) and
//     BRCommunityGameCell (background image + title + a decorative
//     cloud-download icon; the whole cell is the tap target — unlike the
//     share button, downloading doesn't need a separate explicit control
//     since tapping a browse-list card already IS the deliberate action).
//   - New BRRemoteImageLoader: a small NSCache-backed async image loader for
//     the grid's signed Storage URLs, since this file's existing image
//     handling (BRSavedGameCell) only ever dealt with already-in-memory
//     UIImages from local BRGameRecords, never a remote fetch. Flagged in
//     its own header comment in case a project-wide image loader already
//     exists elsewhere and this should be consolidated into it instead.
//   - Pagination via willDisplayCell: triggering loadMoreCommunityGames a
//     few cells before the end of the currently-loaded list.
//   - Tapping a community card shows a download confirmation (cost is
//     shown via the display-only kBRSharedGameDownloadCoinsDisplay
//     constant; the real charge is computed and enforced entirely
//     server-side), then calls download_shared_game, decodes the returned
//     assets, writes them to BRGameLibrary exactly like every other game
//     creation path, and shows the same BRGameResultViewController reveal
//     card used everywhere else — so a downloaded game's first appearance
//     looks identical to a freshly-generated or previously-saved one.
//   - Long-press on a community card now offers Report instead of Delete
//     (you don't own someone else's shared game to delete it; reporting
//     calls br-community's report_game).
//   - Added a simple full-screen blocking spinner (showBlockingSpinnerWithMessage:/
//     hideBlockingSpinner) for the download flow specifically — it's the one
//     action in this file that both costs coins and needs its result in
//     hand before there's anything useful to show next.
//   - Generalized presentShareErrorWithMessage: into
//     presentCommunityErrorWithTitle:message:, now shared by the share,
//     download, and report failure paths instead of being share-specific.
//   - Added performUnauthenticatedBrCommunityRequestWithPayload:timeout:completion:,
//     used only by list_shared_games — the one br-community action that
//     deliberately doesn't require a JWT.
//
// Changes from v2.4:
//   - Added a cloud-share button (top-trailing corner of each saved-game
//     card, "icloud.and.arrow.up") that publishes that game to the
//     community library via br-community's share_game action. Tapping it
//     shows a confirmation sheet first — sharing is always a deliberate,
//     single-game action; there is no bulk-share or auto-share-on-create.
//     While the upload is in flight the button is replaced with a spinner;
//     on success it flashes a green checkmark for ~1.5s before reverting;
//     on failure (auth, rate limit, network) an alert explains why and the
//     button simply reverts to idle so the player can retry.
//   - KNOWN GAP: the confirmation copy is intentionally general ("your
//     title, premise, and images will become visible...") rather than
//     specifically flagging when a shared asset was an uploaded personal
//     photo vs. AI-generated art. BRGameRecord/BRGameLibrary don't persist
//     that distinction — BRCustomGameCreatorViewController tracks it
//     in-memory (BRAssetSourceKind) only while a game is being built, and it
//     never makes it into meta.json on disk. Surfacing it here would require
//     extending BRGameLibrary's save method and BRGameRecord's model to
//     persist a per-slot source kind — out of scope for this pass since it
//     touches BRGameLibrary.m, which hasn't been provided.
//   - There's also no "already shared" tracking yet: re-tapping the cloud
//     button after a successful share publishes a second, separate listing
//     rather than recognizing the first one. Same root cause as above — no
//     shared_game_id is persisted back onto the local record.
//   - Added performBrCommunityRequestWithPayload:timeout:completion: and
//     brCommunityEndpointURL, mirroring
//     BRCustomGameCreatorViewController's EZAuthManager-based pattern for
//     br-ai exactly (same "never hit the network without a real, current
//     token" contract that fixed that file's earlier 401 bug).
//
// Changes from v2.3:
//   - FIXED: the class extension below briefly re-declared onSelection and
//     onClosedWithoutSelection, both already plain `readwrite` properties in
//     BRGamePickerViewController.h. That redeclaration was unnecessary —
//     self.onSelection/self.onClosedWithoutSelection already work from a
//     plain readwrite header property with no extension declaration needed
//     — and Clang correctly rejects it ("illegal redeclaration... attribute
//     must be readwrite, while its primary must be readonly"; that wording
//     is just Clang's way of saying "you can only redeclare to narrow
//     readonly into readwrite, and these weren't readonly to begin with").
//     Removed; both properties now come only from the header, as they
//     should have from the start.
//
// Changes from v2.2:
//   - Picking an existing saved game no longer drops straight into gameplay.
//     It now goes through the same BRGameResultViewController reveal card
//     (title, premise, player/enemy thumbnails, background) used after
//     generating a brand-new custom game — see
//     presentResultScreenForExistingRecord:. Since a saved record is
//     already fully built, markReadyWithRecord: is called immediately
//     (before the card is even presented), so PLAY appears right away with
//     no "Finalizing..." spinner — only the title/premise fade-in reveal
//     plays, same as for a new game.
//   - "Play" on that card dismisses it, then dismisses this picker, then
//     fires onSelection — mirroring the exact two-step hand-off the
//     Workshop's onPlayRequested already uses. "Maybe Later" only dismisses
//     the card, returning to browse other games in this picker.
//
// Changes from v2.1:
//   - Added onClosedWithoutSelection callback (also declared in
//     BRGamePickerViewController.h). Fires from handleCloseTapped after the
//     picker has dismissed itself, so BrainRotViewController can dismiss
//     *itself* in response — leaving BRGameView's chrome behind the picker
//     (empty gameView/d-pad/HUD) visible after the picker dismisses was not
//     a useful state to land in. See BrainRotViewController v2.7 for the
//     receiving end (dismissSelfBackToCaller).
//
// Changes from v2.0:
//   - Added a "✕" close button (top-trailing, below the safe area) that
//     dismisses the picker with no selection. Previously, presenting this
//     full-screen modal left no way back except onSelection firing — if the
//     player opened the picker and changed their mind, the only way out was
//     force-quitting the app.
//   - FIXED the Workshop hand-off. workshopVC.onGameCreated previously called
//     dismissWithRecord:, which both dismisses *and* fires onSelection — but
//     onGameCreated now fires the moment BRGameLibrary finishes its disk
//     write (in parallel with BRGameResultViewController's premise reveal),
//     not when the player has made a choice. The result: the result screen
//     flashed for an instant, then got torn down by this dismiss, while
//     onSelection fired underneath a picker that was still on screen — the
//     picker would then reload (via viewWillAppear) and show the new game as
//     a card, while loadGameRecord: ran invisibly behind it.
//     Now:
//       - onGameCreated only inserts the new record into savedGames and
//         reloads the collection view — no dismiss, no onSelection. The
//         result screen is left to do its job uninterrupted.
//       - onPlayRequested (fired only after the Workshop + result screen
//         have already dismissed themselves) is what now calls
//         dismissWithRecord:, taking the player straight into gameplay —
//         "Maybe Later" simply leaves the picker showing the new game as a
//         card, already reflecting the onGameCreated update.
//   - dismissWithRecord: gained an `animated:` parameter. onPlayRequested
//     uses NO, since the Workshop's own dismiss (picker -> Workshop) already
//     provided the visual transition back to the picker; animating this
//     second dismissal too would add a visible double-flash.
//
// Layout: full-screen dark background, scrollable 2-column UICollectionView.
// Row 0: "✚ NEW GAME" card (always present, spanning full width via a separate
//         section so it never gets displaced by saved games).
// Rows 1+: one card per saved game, newest first.
//
// Each saved-game card:
//   - Background image fills the cell with aspect-fill clipping.
//   - A vertical gradient (clear → 80% black) darkens the bottom two-thirds.
//   - Theme title in bold white overlaid at the bottom.
//   - Creation date in small gray text below the title.
//   - Cloud-share button, top-trailing corner — see BRSavedGameCell.
//   - Long-press triggers a context menu with a destructive Delete action.

#import "BRGamePickerViewController.h"
#import "BRGameLibrary.h"
#import "BRCustomGameCreatorViewController.h" // Linked Workshop Interface
#import "BRGameResultViewController.h"
#import "BRRemoteImageLoader.h"
#import "EZAuthManager.h"
#if DEBUG
#import "BRCommunityAdminViewController.h"
#endif

extern NSString *const kBRHighScoreURL;

static NSString *const kBRNewGameCellIdentifier    = @"BRNewGameCell";
static NSString *const kBRSavedGameCellIdentifier  = @"BRSavedGameCell";
static NSString *const kBRCommunityGameCellIdentifier = @"BRCommunityGameCell";
static NSString *const kBRNewGameSectionIdentifier = @"newGame";

// Display-only — the actual charge is computed and enforced entirely
// server-side in br-community's download_shared_game action. Mirrors that
// file's SHARED_GAME_DOWNLOAD_COINS constant; keep the two in sync if
// pricing ever changes (same "client shows it, server enforces it" split
// already used by BRCustomGameCreatorViewController's coinCostForAssetSlot:).
static const NSInteger kBRSharedGameDownloadCoinsDisplay = 2;

#pragma mark - BRCommunitySharedGame

/// Lightweight in-memory model for one row of list_shared_games. Distinct
/// from BRGameRecord — this represents something not yet downloaded, with
/// remote signed-URL image references instead of local UIImages.
@interface BRCommunitySharedGame : NSObject
@property (nonatomic, copy) NSString *sharedGameId;
@property (nonatomic, copy) NSString *themeTitle;
@property (nonatomic, copy) NSString *premise;
@property (nonatomic, copy, nullable) NSString *createdAt; // ISO8601 string; doubles as the pagination cursor
@property (nonatomic, copy, nullable) NSString *backgroundImageURLString; // used by the grid card
// player/enemy URLs are included in list_shared_games' response but not
// currently used here — the grid card only shows the background, matching
// BRSavedGameCell. download_shared_game returns full base64 assets
// separately once a game is actually downloaded, so these aren't needed for
// that either. Kept on the model in case a future "preview before
// downloading" screen wants them.
@property (nonatomic, copy, nullable) NSString *playerImageURLString;
@property (nonatomic, copy, nullable) NSString *enemyImageURLString;
@end

@implementation BRCommunitySharedGame
@end

#pragma mark - BRSavedGameCell

/// Visual state of a cell's cloud-share button. Idle is the default
/// (tappable, cloud-upload icon); InProgress shows a spinner while
/// share_game is in flight; Success briefly shows a green checkmark before
/// reverting to Idle. There is deliberately no persistent "already shared"
/// state — BRGameRecord/BRGameLibrary don't currently track a shared_game_id
/// per local record, so re-tapping after a successful share will publish a
/// second, separate listing rather than being recognized as "already
/// shared". See this file's changelog for what extending BRGameLibrary to
/// close that gap would require.
typedef NS_ENUM(NSInteger, BRSavedGameCellShareState) {
    BRSavedGameCellShareStateIdle = 0,
    BRSavedGameCellShareStateInProgress,
    BRSavedGameCellShareStateSuccess,
};

/// Private cell: background image + gradient + title/date labels + a
/// cloud-share button in the top-trailing corner.
@interface BRSavedGameCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *backgroundImageView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIActivityIndicatorView *shareSpinner;

/// Fired immediately on tap — the controller owns deciding whether to show
/// a confirmation first, making the network call, and routing the
/// in-progress/success/failure outcome back via setShareState:/an alert.
/// Re-assigned every time the cell is configured, so it always targets the
/// record currently bound to this cell, not whatever was bound when the
/// cell instance was first created.
@property (nonatomic, copy, nullable) void (^onShareTapped)(void);

- (void)configureWithRecord:(BRGameRecord *)record;
- (void)setShareState:(BRSavedGameCellShareState)state;
@end

@implementation BRSavedGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.contentView.layer.cornerRadius  = 12;
    self.contentView.layer.masksToBounds = YES;
    self.contentView.backgroundColor     = [UIColor colorWithWhite:0.12 alpha:1.0];

    // Background image — fills entire cell
    self.backgroundImageView               = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
    self.backgroundImageView.contentMode   = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.clipsToBounds = YES;
    self.backgroundImageView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:self.backgroundImageView];

    // Gradient overlay: clear at top, dark at bottom
    self.gradientLayer              = [CAGradientLayer layer];
    self.gradientLayer.colors       = @[
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithRed:0.02 green:0.0 blue:0.08 alpha:0.85].CGColor,
    ];
    self.gradientLayer.locations    = @[@(0.35), @(1.0)];
    self.gradientLayer.frame        = self.contentView.bounds;
    [self.contentView.layer addSublayer:self.gradientLayer];

    // Theme title
    self.titleLabel               = [[UILabel alloc] init];
    self.titleLabel.font          = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightBold];
    self.titleLabel.textColor     = [UIColor whiteColor];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.titleLabel];

    // Date label
    self.dateLabel           = [[UILabel alloc] init];
    self.dateLabel.font      = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.dateLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.dateLabel];

    CGFloat sidePad = 8;
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:sidePad],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-sidePad],
        [self.titleLabel.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-24],
        [self.dateLabel.leadingAnchor   constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.dateLabel.trailingAnchor  constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.dateLabel.bottomAnchor    constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-8],
    ]];

    // Cloud-share button — top-trailing corner, circular dark backing so the
    // icon stays legible against any background art. A plain UIButton inside
    // the cell intercepts its own taps before the collection view's
    // selection gesture sees them — standard UIKit behavior, no extra
    // shouldReceiveTouch: handling needed.
    UIView *shareBackingView = [[UIView alloc] init];
    shareBackingView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    shareBackingView.layer.cornerRadius = 16;
    shareBackingView.userInteractionEnabled = NO; // purely decorative; shareButton on top handles taps
    shareBackingView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:shareBackingView];

    self.shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareButton setImage:[UIImage systemImageNamed:@"icloud.and.arrow.up"] forState:UIControlStateNormal];
    self.shareButton.tintColor = [UIColor whiteColor];
    [self.shareButton addTarget:self action:@selector(handleShareButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.shareButton];

    self.shareSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.shareSpinner.color = [UIColor whiteColor];
    self.shareSpinner.hidesWhenStopped = YES;
    self.shareSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.shareSpinner];

    [NSLayoutConstraint activateConstraints:@[
        [shareBackingView.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [shareBackingView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        [shareBackingView.widthAnchor    constraintEqualToConstant:32],
        [shareBackingView.heightAnchor   constraintEqualToConstant:32],

        [self.shareButton.centerXAnchor constraintEqualToAnchor:shareBackingView.centerXAnchor],
        [self.shareButton.centerYAnchor constraintEqualToAnchor:shareBackingView.centerYAnchor],
        [self.shareButton.widthAnchor   constraintEqualToConstant:32],
        [self.shareButton.heightAnchor  constraintEqualToConstant:32],

        [self.shareSpinner.centerXAnchor constraintEqualToAnchor:shareBackingView.centerXAnchor],
        [self.shareSpinner.centerYAnchor constraintEqualToAnchor:shareBackingView.centerYAnchor],
    ]];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.gradientLayer.frame = self.contentView.bounds;
}

- (void)configureWithRecord:(BRGameRecord *)record {
    self.titleLabel.text        = record.themeTitle;
    self.backgroundImageView.image = record.backgroundImage; // lazy load from disk

    // Relative date string
    NSDate *created = record.createdDate;
    if (!created) created = [NSDate date];
    NSTimeInterval age = -[created timeIntervalSinceNow];
    NSString *dateString;
    if (age < 60)              dateString = @"Just now";
    else if (age < 3600)       dateString = [NSString stringWithFormat:@"%d min ago",  (int)(age / 60)];
    else if (age < 86400)      dateString = [NSString stringWithFormat:@"%d hr ago",   (int)(age / 3600)];
    else if (age < 86400 * 7)  dateString = [NSString stringWithFormat:@"%d days ago", (int)(age / 86400)];
    else {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterNoStyle;
        dateString = [formatter stringFromDate:created];
    }
    self.dateLabel.text = dateString;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.backgroundImageView.image = nil;
    self.titleLabel.text           = nil;
    self.dateLabel.text            = nil;
    self.onShareTapped             = nil;
    [self setShareState:BRSavedGameCellShareStateIdle];
}

#pragma mark - Share Button

- (void)handleShareButtonTapped {
    if (self.onShareTapped) self.onShareTapped();
}

- (void)setShareState:(BRSavedGameCellShareState)state {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(revertShareStateToIdle) object:nil];

    switch (state) {
        case BRSavedGameCellShareStateIdle:
            self.shareButton.hidden = NO;
            [self.shareButton setImage:[UIImage systemImageNamed:@"icloud.and.arrow.up"] forState:UIControlStateNormal];
            self.shareButton.tintColor = [UIColor whiteColor];
            self.shareButton.enabled = YES;
            [self.shareSpinner stopAnimating];
            break;

        case BRSavedGameCellShareStateInProgress:
            self.shareButton.hidden = YES;
            self.shareButton.enabled = NO;
            [self.shareSpinner startAnimating];
            break;

        case BRSavedGameCellShareStateSuccess:
            [self.shareSpinner stopAnimating];
            self.shareButton.hidden = NO;
            [self.shareButton setImage:[UIImage systemImageNamed:@"checkmark.circle.fill"] forState:UIControlStateNormal];
            self.shareButton.tintColor = [UIColor systemGreenColor];
            self.shareButton.enabled = NO; // briefly inert during the success flash
            [self performSelector:@selector(revertShareStateToIdle) withObject:nil afterDelay:1.5];
            break;
    }
}

- (void)revertShareStateToIdle {
    [self setShareState:BRSavedGameCellShareStateIdle];
}

@end

#pragma mark - BRNewGameCell

/// Simple "New Game" card with a ✚ and text.
@interface BRNewGameCell : UICollectionViewCell
@end

@implementation BRNewGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.contentView.layer.cornerRadius  = 12;
    self.contentView.layer.masksToBounds = YES;
    self.contentView.backgroundColor     = [UIColor colorWithRed:0.05 green:0.0 blue:0.18 alpha:1.0];
    self.contentView.layer.borderColor   = [UIColor systemYellowColor].CGColor;
    self.contentView.layer.borderWidth   = 1.5;

    UILabel *plusLabel      = [[UILabel alloc] init];
    plusLabel.text          = @"✚";
    plusLabel.font          = [UIFont systemFontOfSize:40 weight:UIFontWeightLight];
    plusLabel.textColor     = [UIColor systemYellowColor];
    plusLabel.textAlignment = NSTextAlignmentCenter;
    plusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:plusLabel];

    UILabel *textLabel      = [[UILabel alloc] init];
    textLabel.text          = @"NEW GAME";
    textLabel.font          = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    textLabel.textColor     = [UIColor systemYellowColor];
    textLabel.textAlignment = NSTextAlignmentCenter;
    textLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:textLabel];

    UILabel *subLabel      = [[UILabel alloc] init];
    subLabel.text          = @"Workshop Builder";
    subLabel.font          = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    subLabel.textColor     = [UIColor colorWithWhite:0.55 alpha:1.0];
    subLabel.textAlignment = NSTextAlignmentCenter;
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:subLabel];

    [NSLayoutConstraint activateConstraints:@[
        [plusLabel.centerXAnchor  constraintEqualToAnchor:self.contentView.centerXAnchor],
        [plusLabel.centerYAnchor  constraintEqualToAnchor:self.contentView.centerYAnchor constant:-18],
        [textLabel.centerXAnchor  constraintEqualToAnchor:self.contentView.centerXAnchor],
        [textLabel.topAnchor      constraintEqualToAnchor:plusLabel.bottomAnchor constant:6],
        [subLabel.centerXAnchor   constraintEqualToAnchor:self.contentView.centerXAnchor],
        [subLabel.topAnchor       constraintEqualToAnchor:textLabel.bottomAnchor constant:4],
    ]];
    return self;
}

@end

#pragma mark - BRCommunityGameCell

/// Community-browse card: background image (loaded async from a signed
/// Storage URL) + the same gradient/title treatment as BRSavedGameCell,
/// plus a non-interactive cloud-download icon. Unlike BRSavedGameCell's
/// share button, there's no separate tap target here — the whole cell opens
/// the community-preview reveal card (see
/// presentResultScreenForCommunityGame:), since the card itself — with its
/// DOWNLOAD button showing the cost — is the deliberate confirmation step;
/// a separate alert first would be redundant.
@interface BRCommunityGameCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *backgroundImageView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, weak) NSURLSessionDataTask *imageLoadTask;
@property (nonatomic, copy, nullable) NSString *boundImageURLString;
- (void)configureWithSharedGame:(BRCommunitySharedGame *)game;
@end

@implementation BRCommunityGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.contentView.layer.cornerRadius  = 12;
    self.contentView.layer.masksToBounds = YES;
    self.contentView.backgroundColor     = [UIColor colorWithWhite:0.12 alpha:1.0];

    self.backgroundImageView               = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
    self.backgroundImageView.contentMode   = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.clipsToBounds = YES;
    self.backgroundImageView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:self.backgroundImageView];

    self.gradientLayer           = [CAGradientLayer layer];
    self.gradientLayer.colors    = @[
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithRed:0.02 green:0.0 blue:0.08 alpha:0.85].CGColor,
    ];
    self.gradientLayer.locations = @[@(0.35), @(1.0)];
    self.gradientLayer.frame     = self.contentView.bounds;
    [self.contentView.layer addSublayer:self.gradientLayer];

    self.titleLabel               = [[UILabel alloc] init];
    self.titleLabel.font          = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightBold];
    self.titleLabel.textColor     = [UIColor whiteColor];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.titleLabel];

    UIView *downloadBackingView = [[UIView alloc] init];
    downloadBackingView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    downloadBackingView.layer.cornerRadius = 16;
    downloadBackingView.userInteractionEnabled = NO; // decorative only — see class comment
    downloadBackingView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:downloadBackingView];

    UIImageView *downloadIconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"icloud.and.arrow.down"]];
    downloadIconView.tintColor = [UIColor whiteColor];
    downloadIconView.contentMode = UIViewContentModeScaleAspectFit;
    downloadIconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:downloadIconView];

    CGFloat sidePad = 8;
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:sidePad],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-sidePad],
        [self.titleLabel.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-8],

        [downloadBackingView.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [downloadBackingView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        [downloadBackingView.widthAnchor    constraintEqualToConstant:32],
        [downloadBackingView.heightAnchor   constraintEqualToConstant:32],

        [downloadIconView.centerXAnchor constraintEqualToAnchor:downloadBackingView.centerXAnchor],
        [downloadIconView.centerYAnchor constraintEqualToAnchor:downloadBackingView.centerYAnchor],
        [downloadIconView.widthAnchor   constraintEqualToConstant:18],
        [downloadIconView.heightAnchor  constraintEqualToConstant:18],
    ]];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.gradientLayer.frame = self.contentView.bounds;
}

- (void)configureWithSharedGame:(BRCommunitySharedGame *)game {
    self.titleLabel.text = game.themeTitle;
    self.backgroundImageView.image = nil;

    [self.imageLoadTask cancel];
    self.boundImageURLString = game.backgroundImageURLString;
    if (!game.backgroundImageURLString) return;

    __weak typeof(self) weakSelf = self;
    NSString *requestedURLString = game.backgroundImageURLString;
    self.imageLoadTask = [[BRRemoteImageLoader shared] loadImageFromURLString:requestedURLString
                                                                     completion:^(UIImage * _Nullable image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Guard against this cell having been reused for a different game by
        // the time the network request finishes — cancelling the task in
        // prepareForReuse handles the common case, but this is a cheap
        // belt-and-suspenders check against any race.
        if (![strongSelf.boundImageURLString isEqualToString:requestedURLString]) return;
        strongSelf.backgroundImageView.image = image;
    }];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.imageLoadTask cancel];
    self.imageLoadTask          = nil;
    self.boundImageURLString    = nil;
    self.backgroundImageView.image = nil;
    self.titleLabel.text         = nil;
}

@end

#pragma mark - BRGamePickerViewController

/// Which data set the grid is currently showing. "New Game" only appears in
/// MyGames mode — it makes no sense alongside community browsing.
typedef NS_ENUM(NSInteger, BRPickerTab) {
    BRPickerTabMyGames = 0,
    BRPickerTabCommunity,
};

@interface BRGamePickerViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, assign) BRPickerTab currentTab;
@property (nonatomic, strong) NSArray<BRGameRecord *> *savedGames;

// Community browse state.
@property (nonatomic, strong, nullable) NSArray<BRCommunitySharedGame *> *communityGames;
@property (nonatomic, copy, nullable) NSString *communityNextCursor;
@property (nonatomic, assign) BOOL isLoadingCommunityPage;
@property (nonatomic, assign) BOOL communityReachedEnd;

#if DEBUG
/// Admin panel entry point — only compiled into debug builds. Appears in the
/// top-trailing corner when the Community tab is active. The server still
/// validates BR_ADMIN_CODE independently, so a jailbroken release build
/// that somehow calls the endpoint directly gets a 403.
@property (nonatomic, strong) UIButton *adminButton;
#endif
@end

@implementation BRGamePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:1.0];

    // ── Header ────────────────────────────────────────────────────────────────
    UILabel *headerLabel      = [[UILabel alloc] init];
    headerLabel.text          = @"🕹  BRAINROT";
    headerLabel.font          = [UIFont monospacedSystemFontOfSize:26 weight:UIFontWeightBold];
    headerLabel.textColor     = [UIColor systemYellowColor];
    headerLabel.textAlignment = NSTextAlignmentCenter;
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:headerLabel];

    UILabel *subHeader      = [[UILabel alloc] init];
    subHeader.text          = @"Choose a world or generate a new one";
    subHeader.font          = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    subHeader.textColor     = [UIColor colorWithWhite:0.55 alpha:1.0];
    subHeader.textAlignment = NSTextAlignmentCenter;
    subHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subHeader];

    // Close button: this picker is presented full-screen with no other way
    // back. Dismisses with no selection — onSelection is NOT called, so the
    // presenter (BrainRotViewController) is left exactly as it was.
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setTitle:@"✕" forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    closeButton.tintColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [closeButton addTarget:self action:@selector(handleCloseTapped) forControlEvents:UIControlEventTouchUpInside];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:closeButton];

    // Tab control: switches the grid between locally-saved games and the
    // public community library. "New Game" only ever appears in MyGames —
    // see numberOfSectionsInCollectionView:.
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"My Games", @"Community"]];
    self.currentTab = self.startsOnCommunityTab ? BRPickerTabCommunity : BRPickerTabMyGames;
    self.tabControl.selectedSegmentIndex = self.currentTab;
    [self.tabControl addTarget:self action:@selector(handleTabChanged:) forControlEvents:UIControlEventValueChanged];
    self.tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tabControl];

#if DEBUG
    // Admin panel button — debug builds only. Appears in the top-trailing
    // corner when the Community tab is selected; hidden on My Games to keep
    // the button contextually relevant (all admin actions target community
    // content) and out of sight during normal gameplay sessions.
    self.adminButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.adminButton setImage:[UIImage systemImageNamed:@"shield.lefthalf.filled"]
                     forState:UIControlStateNormal];
    self.adminButton.tintColor = [UIColor systemOrangeColor];
    self.adminButton.hidden = YES; // shown only on Community tab
    [self.adminButton addTarget:self
                         action:@selector(handleAdminButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];
    self.adminButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.adminButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.adminButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [self.adminButton.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.adminButton.widthAnchor    constraintEqualToConstant:44],
        [self.adminButton.heightAnchor   constraintEqualToConstant:44],
    ]];
#endif

    // ── Collection view ───────────────────────────────────────────────────────
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing      = 12;
    layout.sectionInset            = UIEdgeInsetsMake(12, 16, 24, 16);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                             collectionViewLayout:layout];
    self.collectionView.backgroundColor     = [UIColor clearColor];
    self.collectionView.dataSource          = self;
    self.collectionView.delegate            = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.collectionView registerClass:[BRNewGameCell class]
            forCellWithReuseIdentifier:kBRNewGameCellIdentifier];
    [self.collectionView registerClass:[BRSavedGameCell class]
            forCellWithReuseIdentifier:kBRSavedGameCellIdentifier];
    [self.collectionView registerClass:[BRCommunityGameCell class]
            forCellWithReuseIdentifier:kBRCommunityGameCellIdentifier];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [headerLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [headerLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subHeader.topAnchor constraintEqualToAnchor:headerLabel.bottomAnchor constant:4],
        [subHeader.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [closeButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [closeButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [closeButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
        [closeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.tabControl.topAnchor constraintEqualToAnchor:subHeader.bottomAnchor constant:14],
        [self.tabControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.tabControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.collectionView.topAnchor constraintEqualToAnchor:self.tabControl.bottomAnchor constant:12],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self reloadSavedGames];
    if (self.currentTab == BRPickerTabCommunity) [self loadFirstCommunityPageIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSavedGames];
}

- (void)handleTabChanged:(UISegmentedControl *)sender {
    self.currentTab = (BRPickerTab)sender.selectedSegmentIndex;
    if (self.currentTab == BRPickerTabCommunity) {
        [self loadFirstCommunityPageIfNeeded];
    }
    [self.collectionView reloadData];
    [self.collectionView setContentOffset:CGPointZero animated:NO];
#if DEBUG
    self.adminButton.hidden = (self.currentTab != BRPickerTabCommunity);
#endif
}

#if DEBUG
- (void)handleAdminButtonTapped {
    NSURL *referenceURL = [NSURL URLWithString:kBRHighScoreURL];
    NSString *resolvedHost = referenceURL.host ?: @"localhost:54321";
    NSURL *endpointURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://%@/functions/v1/br-community", resolvedHost]];

    BRCommunityAdminViewController *adminVC =
        [[BRCommunityAdminViewController alloc] initWithBrCommunityEndpointURL:endpointURL];
    UINavigationController *navController =
        [[UINavigationController alloc] initWithRootViewController:adminVC];
    navController.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navController animated:YES completion:nil];
}
#endif

- (void)reloadSavedGames {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<BRGameRecord *> *records = [BRGameLibrary.shared allRecords];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.savedGames = records;
            if (self.currentTab == BRPickerTabMyGames) {
                [self.collectionView reloadData];
            }
        });
    });
}

#pragma mark - UICollectionView sizing

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    CGFloat totalWidth  = CGRectGetWidth(self.collectionView.bounds);
    CGFloat sideInsets  = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat spacing     = layout.minimumInteritemSpacing;
    CGFloat cellWidth   = floor((totalWidth - sideInsets - spacing) / 2.0);
    CGFloat cellHeight  = cellWidth * 1.25;
    if (!CGSizeEqualToSize(layout.itemSize, CGSizeMake(cellWidth, cellHeight))) {
        layout.itemSize = CGSizeMake(cellWidth, cellHeight);
        [layout invalidateLayout];
    }
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    // Community mode has a single flat section (no "New Game" card —
    // creating games has nothing to do with browsing the community library).
    return (self.currentTab == BRPickerTabCommunity) ? 1 : 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    if (self.currentTab == BRPickerTabCommunity) {
        return (NSInteger)self.communityGames.count;
    }
    return (section == 0) ? 1 : (NSInteger)self.savedGames.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentTab == BRPickerTabCommunity) {
        BRCommunityGameCell *cell =
            [collectionView dequeueReusableCellWithReuseIdentifier:kBRCommunityGameCellIdentifier
                                                      forIndexPath:indexPath];
        BRCommunitySharedGame *game = self.communityGames[indexPath.item];
        [cell configureWithSharedGame:game];
        return cell;
    }

    if (indexPath.section == 0) {
        return [collectionView dequeueReusableCellWithReuseIdentifier:kBRNewGameCellIdentifier
                                                         forIndexPath:indexPath];
    }
    BRSavedGameCell *cell =
        [collectionView dequeueReusableCellWithReuseIdentifier:kBRSavedGameCellIdentifier
                                                  forIndexPath:indexPath];
    BRGameRecord *record = self.savedGames[indexPath.item];
    [cell configureWithRecord:record];

    // Re-assigned on every dequeue/reuse, so this always targets whichever
    // record is currently bound to this cell. Captures `record` (the object
    // itself) rather than `indexPath`, so an in-flight share survives the
    // array mutating elsewhere (e.g. a delete) without going stale.
    __weak typeof(self) weakSelf = self;
    __weak BRSavedGameCell *weakCell = cell;
    cell.onShareTapped = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        __strong BRSavedGameCell *strongCell = weakCell;
        if (!strongSelf || !strongCell) return;
        [strongSelf presentShareConfirmationForRecord:record cell:strongCell];
    };

    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView
        willDisplayCell:(UICollectionViewCell *)cell
     forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentTab != BRPickerTabCommunity) return;
    if (self.isLoadingCommunityPage || self.communityReachedEnd) return;
    // Start loading the next page a few cells before the user actually
    // reaches the end, so the next batch is usually ready by the time they
    // scroll there.
    NSInteger triggerIndex = MAX(0, (NSInteger)self.communityGames.count - 4);
    if (indexPath.item >= triggerIndex) {
        [self loadMoreCommunityGames];
    }
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentTab == BRPickerTabCommunity) {
        BRCommunitySharedGame *game = self.communityGames[indexPath.item];
        [self presentResultScreenForCommunityGame:game];
        return;
    }

    if (indexPath.section == 0) {
        BRCustomGameCreatorViewController *workshopVC = [[BRCustomGameCreatorViewController alloc] init];

        __weak typeof(self) weakSelf = self;

        // Fires as soon as BRGameLibrary finishes writing the new record —
        // while BRGameResultViewController is still showing the premise
        // reveal / "Finalizing..." state on top of the Workshop. Just fold
        // the new record into our own list so it's ready to show as a card
        // if the player backs out via "Maybe Later"; do NOT dismiss or call
        // onSelection here.
        workshopVC.onGameCreated = ^(BRGameRecord * _Nonnull record) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSMutableArray<BRGameRecord *> *updated = [strongSelf.savedGames mutableCopy] ?: [NSMutableArray array];
            [updated insertObject:record atIndex:0]; // newest first, matches BRGameLibrary ordering
            strongSelf.savedGames = [updated copy];
            [strongSelf.collectionView reloadData];
        };

        // Fires only after the Workshop and its result screen have already
        // dismissed themselves (back to this picker). This is the moment to
        // hand off to gameplay, exactly as if the player had tapped an
        // existing saved-game card.
        workshopVC.onPlayRequested = ^(BRGameRecord * _Nonnull record) {
            [weakSelf dismissWithRecord:record animated:NO];
        };

        UINavigationController *navWrapper = [[UINavigationController alloc] initWithRootViewController:workshopVC];
        navWrapper.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:navWrapper animated:YES completion:nil];
    } else {
        BRGameRecord *selectedRecord = self.savedGames[indexPath.item];
        [self presentResultScreenForExistingRecord:selectedRecord];
    }
}

/// Shows the same premise/character/background reveal card used right after
/// a new game finishes generating — but for a record that's already fully
/// built, so there's no "Finalizing..." wait: markReadyWithRecord: is called
/// immediately, before the screen is even presented, which the result
/// screen's own viewDidLoad already knows how to reflect with no animation
/// (see BRGameResultViewController's markReadyWithRecord:/viewDidLoad).
///
/// "Play" dismisses this card, then this picker, then fires onSelection —
/// the exact same two-step hand-off the Workshop's onPlayRequested uses.
/// "Maybe Later" only dismisses this card, returning to browse other games.
- (void)presentResultScreenForExistingRecord:(BRGameRecord *)record {
    BRGameResultViewController *resultVC =
        [BRGameResultViewController resultControllerWithTitle:record.themeTitle
                                                        premise:record.premise
                                                    playerImage:record.playerImage
                                                     enemyImage:record.enemyImage
                                                backgroundImage:record.backgroundImage];
    [resultVC markReadyWithRecord:record];

    __weak typeof(self) weakSelf = self;
    resultVC.onPlayTapped = ^(BRGameRecord * _Nonnull tappedRecord) {
        if (weakSelf.onSlotThemeSelection) {
            void (^slotHandler)(BRGameRecord *) = weakSelf.onSlotThemeSelection;
            UIViewController *slotPicker = weakSelf.presentingViewController;
            if (slotPicker) [slotPicker dismissViewControllerAnimated:YES completion:^{ slotHandler(tappedRecord); }];
            else [weakSelf dismissViewControllerAnimated:YES completion:^{ slotHandler(tappedRecord); }];
            return;
        }
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            [weakSelf dismissWithRecord:tappedRecord animated:NO];
        }];
    };
    resultVC.onMaybeLaterTapped = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    };

    resultVC.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:resultVC animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView
    contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath
                                         point:(CGPoint)point
    API_AVAILABLE(ios(13.0)) {
    if (self.currentTab == BRPickerTabCommunity) {
        BRCommunitySharedGame *game = self.communityGames[indexPath.item];
        return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                       previewProvider:nil
                                                        actionProvider:^UIMenu *(NSArray *suggestedActions) {
            UIAction *reportAction = [UIAction actionWithTitle:@"Report"
                                                          image:[UIImage systemImageNamed:@"flag"]
                                                     identifier:nil
                                                        handler:^(__kindof UIAction *action) {
                [self confirmReportCommunityGame:game];
            }];
            reportAction.attributes = UIMenuElementAttributesDestructive;
            return [UIMenu menuWithTitle:game.themeTitle children:@[reportAction]];
        }];
    }

    if (indexPath.section == 0) return nil;

    BRGameRecord *record = self.savedGames[indexPath.item];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray *suggestedActions) {
        UIAction *deleteAction = [UIAction actionWithTitle:@"Delete"
                                                     image:[UIImage systemImageNamed:@"trash"]
                                                identifier:nil
                                                   handler:^(__kindof UIAction *action) {
            [self confirmDeleteRecord:record atIndexPath:indexPath];
        }];
        deleteAction.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:record.themeTitle children:@[deleteAction]];
    }];
}

- (void)confirmDeleteRecord:(BRGameRecord *)record atIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Delete \"%@\"?", record.themeTitle]
                         message:@"This permanently removes the game and its images."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [BRGameLibrary.shared deleteRecord:record];
        NSMutableArray *mutable = [self.savedGames mutableCopy];
        [mutable removeObjectAtIndex:indexPath.item];
        self.savedGames = [mutable copy];
        [self.collectionView deleteItemsAtIndexPaths:@[indexPath]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Community Browse (list_shared_games)

/// Kicks off the first page load the first time the Community tab is
/// selected. communityGames starts nil specifically so this can tell
/// "never tried" apart from "tried and got zero results" — re-selecting the
/// tab after that does NOT reload from scratch (pull-to-refresh isn't wired
/// up in this pass; switching away and back keeps whatever was loaded).
- (void)loadFirstCommunityPageIfNeeded {
    if (self.communityGames != nil) return;
    self.communityGames = @[];
    self.communityNextCursor = nil;
    self.communityReachedEnd = NO;
    [self loadMoreCommunityGames];
}

- (void)loadMoreCommunityGames {
    if (self.isLoadingCommunityPage || self.communityReachedEnd) return;
    self.isLoadingCommunityPage = YES;

    NSMutableDictionary *payload = [@{@"action": @"list_shared_games", @"limit": @20} mutableCopy];
    if (self.communityNextCursor) payload[@"before"] = self.communityNextCursor;

    // list_shared_games doesn't require a session — browsing the community
    // library works whether or not the player is signed in. Only
    // downloading, sharing, and reporting require auth (enforced
    // server-side either way).
    __weak typeof(self) weakSelf = self;
    [self performUnauthenticatedBrCommunityRequestWithPayload:payload
                                                        timeout:30.0
                                                     completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleCommunityListResponseData:data response:response error:error];
        });
    }];
}

- (void)handleCommunityListResponseData:(nullable NSData *)data
                                response:(nullable NSURLResponse *)response
                                   error:(nullable NSError *)error {
    self.isLoadingCommunityPage = NO;

    if (error) {
        [self presentCommunityErrorWithTitle:@"Couldn't Load Community Games"
                                      message:error.localizedDescription ?: @"Network error."];
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

    if (httpResponse.statusCode != 200 || ![json[@"success"] boolValue]) {
        [self presentCommunityErrorWithTitle:@"Couldn't Load Community Games"
                                      message:json[@"error"] ?: @"Failed to load community games. Please try again."];
        return;
    }

    NSArray<NSDictionary *> *rawItems = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
    NSMutableArray<BRCommunitySharedGame *> *parsed = [NSMutableArray arrayWithCapacity:rawItems.count];
    for (NSDictionary *raw in rawItems) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        if (![raw[@"shared_game_id"] isKindOfClass:[NSString class]]) continue; // malformed row — skip rather than crash

        BRCommunitySharedGame *game = [BRCommunitySharedGame new];
        game.sharedGameId             = raw[@"shared_game_id"];
        game.themeTitle               = [raw[@"theme_title"] isKindOfClass:[NSString class]] ? raw[@"theme_title"] : @"Untitled";
        game.premise                  = [raw[@"premise"] isKindOfClass:[NSString class]] ? raw[@"premise"] : @"";
        game.createdAt                = [raw[@"created_at"] isKindOfClass:[NSString class]] ? raw[@"created_at"] : nil;
        game.backgroundImageURLString = [raw[@"background_image_url"] isKindOfClass:[NSString class]] ? raw[@"background_image_url"] : nil;
        game.playerImageURLString     = [raw[@"player_image_url"] isKindOfClass:[NSString class]] ? raw[@"player_image_url"] : nil;
        game.enemyImageURLString      = [raw[@"enemy_image_url"] isKindOfClass:[NSString class]] ? raw[@"enemy_image_url"] : nil;
        [parsed addObject:game];
    }

    NSMutableArray<BRCommunitySharedGame *> *updated = [self.communityGames mutableCopy] ?: [NSMutableArray array];
    [updated addObjectsFromArray:parsed];
    self.communityGames = [updated copy];

    NSString *nextCursor = [json[@"next_cursor"] isKindOfClass:[NSString class]] ? json[@"next_cursor"] : nil;
    self.communityNextCursor = nextCursor;
    self.communityReachedEnd = (nextCursor == nil);

    if (self.currentTab == BRPickerTabCommunity) {
        [self.collectionView reloadData];
    }
}

#pragma mark - Community Download (download_shared_game)

/// Presents the same reveal-card screen used everywhere else in this app,
/// pre-filled with the title/premise/thumbnails already known from
/// list_shared_games — no confirmation alert needed first, since seeing the
/// full card (with its DOWNLOAD button showing the cost) before committing
/// already serves that purpose. The actual network call + local save only
/// happen once the player taps DOWNLOAD, via the downloadHandler block.
- (void)presentResultScreenForCommunityGame:(BRCommunitySharedGame *)game {
    __weak typeof(self) weakSelf = self;

    BRGameResultViewController *resultVC =
        [BRGameResultViewController resultControllerForCommunityPreviewWithTitle:game.themeTitle
                                                                            premise:game.premise
                                                              playerImageURLString:game.playerImageURLString
                                                               enemyImageURLString:game.enemyImageURLString
                                                          backgroundImageURLString:game.backgroundImageURLString
                                                                   downloadHandler:^(void (^completion)(BRGameRecord * _Nullable, NSString * _Nullable)) {
        [weakSelf performDownloadForCommunityGame:game completion:completion];
    }];

    resultVC.onPlayTapped = ^(BRGameRecord * _Nonnull record) {
        if (weakSelf.onSlotThemeSelection) {
            void (^slotHandler)(BRGameRecord *) = weakSelf.onSlotThemeSelection;
            // The Community picker is presented over the Slot picker. Dismiss
            // from that presenter so the entire card + Community stack goes
            // away before the Slot picker pushes the machine.
            UIViewController *slotPicker = weakSelf.presentingViewController;
            if (slotPicker) [slotPicker dismissViewControllerAnimated:YES completion:^{ slotHandler(record); }];
            else [weakSelf dismissViewControllerAnimated:YES completion:^{ slotHandler(record); }];
            return;
        }
        [weakSelf dismissViewControllerAnimated:YES completion:^{
            [weakSelf dismissWithRecord:record animated:NO];
        }];
    };
    resultVC.onMaybeLaterTapped = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    };

    resultVC.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:resultVC animated:YES completion:nil];
}

/// The actual network call + local save, now structured around a
/// completion block (BRGameResultDownloadHandler's contract) instead of
/// managing its own spinner UI — BRGameResultViewController owns showing
/// "Downloading..." and reverting to DOWNLOAD on failure now. Still updates
/// self.savedGames on success so "My Games" reflects the new game
/// immediately if the player switches tabs.
- (void)performDownloadForCommunityGame:(BRCommunitySharedGame *)game
                              completion:(void (^)(BRGameRecord * _Nullable record, NSString * _Nullable errorMessage))completion {
    BRGameRecord *existing = [BRGameLibrary.shared existingCommunityRecordWithSharedGameID:game.sharedGameId themeTitle:game.themeTitle premise:game.premise];
    if (existing) { completion(existing, nil); return; }
    NSDictionary *payload = @{@"action": @"download_shared_game", @"shared_game_id": game.sharedGameId};
    __weak typeof(self) weakSelf = self;
    [self performBrCommunityRequestWithPayload:payload
                                        timeout:60.0
                                     completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { completion(nil, @"Something went wrong. Please try again."); return; }
            [strongSelf handleDownloadResponseData:data response:response error:error sharedGameID:game.sharedGameId completion:completion];
        });
    }];
}

- (void)handleDownloadResponseData:(nullable NSData *)data
                           response:(nullable NSURLResponse *)response
                              error:(nullable NSError *)error
                       sharedGameID:(NSString *)sharedGameID
                         completion:(void (^)(BRGameRecord * _Nullable record, NSString * _Nullable errorMessage))completion {
    if (error) {
        if ([error.domain isEqualToString:@"BRCommunityAuth"]) {
            completion(nil, @"Please sign in to download community games.");
        } else {
            completion(nil, [NSString stringWithFormat:@"Network error: %@", error.localizedDescription]);
        }
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

    if (httpResponse.statusCode == 402) {
        NSNumber *cost = [json[@"cost"] isKindOfClass:[NSNumber class]] ? json[@"cost"] : @(kBRSharedGameDownloadCoinsDisplay);
        NSNumber *balance = [json[@"balance"] isKindOfClass:[NSNumber class]] ? json[@"balance"] : @0;
        completion(nil, [NSString stringWithFormat:@"Not enough coins — this costs %@, you have %@.", cost, balance]);
        return;
    }
    if (httpResponse.statusCode == 404) {
        completion(nil, @"This game is no longer available.");
        return;
    }
    if (httpResponse.statusCode != 200 || ![json[@"success"] boolValue]) {
        completion(nil, json[@"error"] ?: @"Failed to download this game. Please try again.");
        return;
    }

    NSDictionary *assets = [json[@"assets"] isKindOfClass:[NSDictionary class]] ? json[@"assets"] : @{};
    NSData *playerData     = [assets[@"player"] isKindOfClass:[NSString class]] ? [[NSData alloc] initWithBase64EncodedString:assets[@"player"] options:0] : nil;
    NSData *enemyData       = [assets[@"enemy"] isKindOfClass:[NSString class]] ? [[NSData alloc] initWithBase64EncodedString:assets[@"enemy"] options:0] : nil;
    NSData *backgroundData = [assets[@"bg"] isKindOfClass:[NSString class]] ? [[NSData alloc] initWithBase64EncodedString:assets[@"bg"] options:0] : nil;
    UIImage *playerImage     = playerData ? [UIImage imageWithData:playerData] : nil;
    UIImage *enemyImage       = enemyData ? [UIImage imageWithData:enemyData] : nil;
    UIImage *backgroundImage = backgroundData ? [UIImage imageWithData:backgroundData] : nil;

    if (!playerImage || !enemyImage || !backgroundImage) {
        completion(nil, @"Received incomplete image data. Please try again.");
        return;
    }

    NSNumber *seedNumber = [json[@"seed"] isKindOfClass:[NSNumber class]] ? json[@"seed"] : @0;
    NSArray *items   = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
    NSArray *enemies = [json[@"enemies"] isKindOfClass:[NSArray class]] ? json[@"enemies"] : @[];

    __weak typeof(self) weakSelf = self;
    [BRGameLibrary.shared saveGameWithThemeTitle:[json[@"theme_title"] isKindOfClass:[NSString class]] ? json[@"theme_title"] : @"Untitled"
                                          premise:[json[@"premise"] isKindOfClass:[NSString class]] ? json[@"premise"] : @""
                                             hint:[json[@"hint"] isKindOfClass:[NSString class]] ? json[@"hint"] : @""
                                            items:items
                                          enemies:enemies
                                             seed:seedNumber
                                  backgroundImage:backgroundImage
                                      playerImage:playerImage
                                       enemyImage:enemyImage
                                       completion:^(BRGameRecord * _Nonnull record) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                [BRGameLibrary.shared markRecord:record downloadedFromCommunityGameID:sharedGameID];
                NSMutableArray<BRGameRecord *> *updated = [strongSelf.savedGames mutableCopy] ?: [NSMutableArray array];
                [updated insertObject:record atIndex:0];
                strongSelf.savedGames = [updated copy];
            }
            completion(record, nil);
        });
    }];
}

#pragma mark - Community Report (report_game)

- (void)confirmReportCommunityGame:(BRCommunitySharedGame *)game {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Report \"%@\"?", game.themeTitle]
                         message:@"This flags the game for review and will hide it automatically once enough players report it."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Report"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self performReportForCommunityGame:game];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performReportForCommunityGame:(BRCommunitySharedGame *)game {
    NSDictionary *payload = @{@"action": @"report_game", @"shared_game_id": game.sharedGameId};
    __weak typeof(self) weakSelf = self;
    [self performBrCommunityRequestWithPayload:payload
                                        timeout:30.0
                                     completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                if ([error.domain isEqualToString:@"BRCommunityAuth"]) {
                    [strongSelf presentCommunityErrorWithTitle:@"Sign In Required" message:@"Please sign in to report games."];
                } else {
                    [strongSelf presentCommunityErrorWithTitle:@"Couldn't Report" message:error.localizedDescription ?: @"Network error."];
                }
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode != 200) {
                [strongSelf presentCommunityErrorWithTitle:@"Couldn't Report" message:@"Failed to submit report. Please try again."];
                return;
            }

            // Lightweight, self-dismissing acknowledgment — a routine "got
            // it, thanks" doesn't need a button the player has to tap.
            UIAlertController *ack = [UIAlertController alertControllerWithTitle:nil
                                                                           message:@"Thanks — this game has been reported for review."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [strongSelf presentViewController:ack animated:YES completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [ack dismissViewControllerAnimated:YES completion:nil];
                });
            }];
        });
    }];
}

#pragma mark - Share to Community

/// Confirms before publishing — sharing must always be a deliberate,
/// per-game action, never automatic or bulk. The copy here is intentionally
/// general rather than calling out uploaded-photo assets specifically:
/// BRGameRecord doesn't currently track whether a given asset slot came
/// from an AI prompt or an uploaded photo (that distinction only exists
/// transiently inside BRCustomGameCreatorViewController while a game is
/// being built, and is never persisted to disk) — see this file's
/// changelog for what closing that gap would require.
- (void)presentShareConfirmationForRecord:(BRGameRecord *)record cell:(BRSavedGameCell *)cell {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Share \"%@\"?", record.themeTitle]
                         message:@"Your title, premise, and images will become visible to anyone who browses or downloads the community library. This publishes immediately."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Share to Community"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self performShareForRecord:record cell:cell];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performShareForRecord:(BRGameRecord *)record cell:(BRSavedGameCell *)cell {
    [cell setShareState:BRSavedGameCellShareStateInProgress];

    UIImage *playerImage     = record.playerImage;
    UIImage *enemyImage       = record.enemyImage;
    UIImage *backgroundImage = record.backgroundImage;
    if (!playerImage || !enemyImage || !backgroundImage) {
        [cell setShareState:BRSavedGameCellShareStateIdle];
        [self presentCommunityErrorWithTitle:@"Couldn't Share" message:@"This game is missing one or more images and can't be shared."];
        return;
    }

    NSData *playerData     = UIImagePNGRepresentation(playerImage);
    NSData *enemyData       = UIImagePNGRepresentation(enemyImage);
    NSData *backgroundData = UIImagePNGRepresentation(backgroundImage);
    if (!playerData || !enemyData || !backgroundData) {
        [cell setShareState:BRSavedGameCellShareStateIdle];
        [self presentCommunityErrorWithTitle:@"Couldn't Share" message:@"Failed to prepare images for upload."];
        return;
    }

    NSDictionary *payload = @{
        @"action": @"share_game",
        @"theme_title": record.themeTitle ?: @"",
        @"premise": record.premise ?: @"",
        @"hint": record.hint ?: @"",
        @"items": record.items ?: @[],
        @"enemies": record.enemies ?: @[],
        @"seed": record.seed ?: @0,
        @"player_image_b64": [playerData base64EncodedStringWithOptions:0],
        @"enemy_image_b64": [enemyData base64EncodedStringWithOptions:0],
        @"background_image_b64": [backgroundData base64EncodedStringWithOptions:0],
    };

    __weak typeof(self) weakSelf = self;
    __weak BRSavedGameCell *weakCell = cell;
    [self performBrCommunityRequestWithPayload:payload timeout:60.0 completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleShareResponseData:data response:response error:error cell:weakCell];
        });
    }];
}

- (void)handleShareResponseData:(nullable NSData *)data
                        response:(nullable NSURLResponse *)response
                           error:(nullable NSError *)error
                            cell:(nullable BRSavedGameCell *)cell {
    if (error) {
        [cell setShareState:BRSavedGameCellShareStateIdle];
        if ([error.domain isEqualToString:@"BRCommunityAuth"]) {
            [self presentCommunityErrorWithTitle:@"Sign In Required" message:@"Please sign in to share games."];
        } else {
            [self presentCommunityErrorWithTitle:@"Couldn't Share" message:[NSString stringWithFormat:@"Network error: %@", error.localizedDescription]];
        }
        return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

    if (httpResponse.statusCode == 429) {
        [cell setShareState:BRSavedGameCellShareStateIdle];
        NSString *message = json[@"message"] ?: @"You've reached today's share limit. Try again tomorrow.";
        [self presentCommunityErrorWithTitle:@"Couldn't Share" message:message];
        return;
    }

    if (httpResponse.statusCode != 200 || ![json[@"success"] boolValue]) {
        [cell setShareState:BRSavedGameCellShareStateIdle];
        NSString *message = json[@"error"] ?: @"Failed to share this game. Please try again.";
        [self presentCommunityErrorWithTitle:@"Couldn't Share" message:message];
        return;
    }

    [cell setShareState:BRSavedGameCellShareStateSuccess];
}

/// Shared error-alert presenter for every br-community failure path (share,
/// download, report, list). `title` lets each caller stay specific
/// ("Couldn't Share" vs "Not Enough Coins" vs "Sign In Required") while
/// reusing one alert-construction implementation.
- (void)presentCommunityErrorWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - br-community Network

/// Resolves the br-community edge function URL from the same project host
/// used elsewhere in the app (kBRHighScoreURL) — mirrors
/// BRCustomGameCreatorViewController's brAIEndpointURL exactly, just
/// pointed at a different function name.
- (NSURL *)brCommunityEndpointURL {
    NSURL *referenceURL = [NSURL URLWithString:kBRHighScoreURL];
    NSString *resolvedHost = referenceURL.host ? referenceURL.host : @"localhost:54321";
    NSString *endpointPath = [NSString stringWithFormat:@"https://%@/functions/v1/br-community", resolvedHost];
    return [NSURL URLWithString:endpointPath];
}

/// Fetches a current, refreshed-if-needed access token from EZAuthManager
/// and, if one is available, POSTs `payload` to br-community as JSON with
/// it attached as a Bearer token. Mirrors
/// BRCustomGameCreatorViewController's performBrAIRequestWithPayload: —
/// same "never hit the network with an empty/stale token" contract that
/// fixed the 401 bug there. If the player isn't signed in, `completion` is
/// called with a "BRCommunityAuth"/401 error and the network is never
/// touched.
- (void)performBrCommunityRequestWithPayload:(NSDictionary *)payload
                                       timeout:(NSTimeInterval)timeout
                                    completion:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString * _Nullable token, NSError * _Nullable authError) {
        if (token.length == 0) {
            NSError *signInError = [NSError errorWithDomain:@"BRCommunityAuth"
                                                         code:401
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Please sign in to use Community sharing."}];
            completion(nil, nil, authError ?: signInError);
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self brCommunityEndpointURL]];
        request.timeoutInterval = timeout;
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

        NSError *serializationError = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&serializationError];
        if (serializationError) {
            completion(nil, nil, serializationError);
            return;
        }

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:completion] resume];
    }];
}

/// Unauthenticated counterpart to performBrCommunityRequestWithPayload: —
/// used only by list_shared_games, which br-community deliberately doesn't
/// require a JWT for (browsing the public library shouldn't be gated behind
/// sign-in, even though downloading/sharing/reporting all are). Skips
/// EZAuthManager entirely; no Authorization header is attached.
- (void)performUnauthenticatedBrCommunityRequestWithPayload:(NSDictionary *)payload
                                                       timeout:(NSTimeInterval)timeout
                                                    completion:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self brCommunityEndpointURL]];
    request.timeoutInterval = timeout;
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *serializationError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&serializationError];
    if (serializationError) {
        completion(nil, nil, serializationError);
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:completion] resume];
}

#pragma mark - Dismiss

- (void)dismissWithRecord:(nullable BRGameRecord *)record animated:(BOOL)animated {
    void (^selectionBlock)(BRGameRecord *) = self.onSelection;
    [self dismissViewControllerAnimated:animated completion:^{
        if (selectionBlock) selectionBlock(record);
    }];
}

/// Closes the picker with no selection at all — onSelection is NOT called.
/// The presenter (BrainRotViewController) is left exactly as it was; this is
/// "I changed my mind", not "load nothing" (which onSelection has no
/// representation for anyway — its two cases are "load this saved record"
/// and "start a new run").
- (void)handleCloseTapped {
    void (^closedBlock)(void) = self.onClosedWithoutSelection;
    // Dismiss self.presentingViewController (BrainRotViewController) rather
    // than self (the picker). When a presenting VC is dismissed it takes its
    // presented VC with it, so both the picker and BrainRotVC collapse in one
    // animation from the main VC's perspective — no brief reveal of the blank
    // BrainRotVC between the picker sliding away and BrainRotVC sliding away.
    // BrainRotVC's onClosedWithoutSelection block still fires afterward; since
    // BrainRotVC is already gone at that point, dismissSelfBackToCaller is a
    // harmless no-op (self.presentingViewController will be nil).
    UIViewController *presenter = self.presentingViewController;
    if (presenter) {
        [presenter dismissViewControllerAnimated:YES completion:^{
            if (closedBlock) closedBlock();
        }];
    } else {
        // Fallback: if somehow the picker has no presenter (e.g. pushed onto
        // a nav stack instead), dismiss ourselves as before.
        [self dismissViewControllerAnimated:YES completion:^{
            if (closedBlock) closedBlock();
        }];
    }
}

@end
