//  BrainRotViewController.m
//  BrainRotGame
//
//  The main view controller. This file coordinates UI, the model, simple input, and AI calls.
//  IMPORTANT: This code uses the assumed synchronous helper:
//    - (NSString *)callChatModel:(NSString *)model withPrompt:(NSString *)prompt
//  If your environment exposes an async API instead, adapt the calls to use completion blocks.
//

#import "BrainRotViewController.h"
#import "BRGameModel.h"
#import "BRGameView.h"

@interface BrainRotViewController () {
    // track whether we've already shown the end-of-run alert for the current run
    BOOL alertFired;
}

// UI
@property (nonatomic, strong) BRGameView *gameView;
@property (nonatomic, strong) UILabel *flavorLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *upBtn;
@property (nonatomic, strong) UIButton *downBtn;
@property (nonatomic, strong) UIButton *leftBtn;
@property (nonatomic, strong) UIButton *rightBtn;
@property (nonatomic, strong) UIButton *actionBtn;
@property (nonatomic, strong) UIButton *restartBtn;

// Model
@property (nonatomic, strong) BRGameModel *model;

// Inventory (simple)
@property (nonatomic, strong) NSMutableArray<NSString*> *inventory;

// A small timer to refresh UI
@property (nonatomic, strong) NSTimer *tickTimer;

@end

@implementation BrainRotViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Ensure alert flag starts cleared in memory and persisted state for a fresh run
    alertFired = NO;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"BRAlertFired"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Top flavor
    self.flavorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.flavorLabel.numberOfLines = 4;
    self.flavorLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.flavorLabel.textAlignment = NSTextAlignmentLeft;
    [self.view addSubview:self.flavorLabel];

    // status
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    [self.view addSubview:self.statusLabel];

    // Game view
    self.gameView = [[BRGameView alloc] initWithFrame:CGRectZero];
    self.gameView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.gameView.layer.cornerRadius = 8;
    self.gameView.layer.masksToBounds = YES;
    [self.view addSubview:self.gameView];

    // Movement buttons
    self.upBtn = [self makeButtonWithTitle:@"▲" selector:@selector(moveUp)];
    self.downBtn = [self makeButtonWithTitle:@"▼" selector:@selector(moveDown)];
    self.leftBtn = [self makeButtonWithTitle:@"◀︎" selector:@selector(moveLeft)];
    self.rightBtn = [self makeButtonWithTitle:@"▶︎" selector:@selector(moveRight)];
    [self.view addSubview:self.upBtn];
    [self.view addSubview:self.downBtn];
    [self.view addSubview:self.leftBtn];
    [self.view addSubview:self.rightBtn];

    // Action button (use item / interact)
    self.actionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.actionBtn setTitle:@"Use" forState:UIControlStateNormal];
    self.actionBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.actionBtn addTarget:self action:@selector(useAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.actionBtn];

    // Restart
    self.restartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.restartBtn setTitle:@"New Run" forState:UIControlStateNormal];
    [self.restartBtn addTarget:self action:@selector(startNewRun) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.restartBtn];

    // layout - use simple frames to keep code self-contained
    [self layoutViews];

    // start
    self.inventory = [NSMutableArray array];
    [self startNewRun];

    // refresh timer
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutViews];
}

- (void)layoutViews {
    CGFloat margin = 14;
    CGFloat topY = self.view.safeAreaInsets.top + margin;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    self.flavorLabel.frame = CGRectMake(margin, topY, width - margin*2, 64);
    self.statusLabel.frame = CGRectMake(margin, CGRectGetMaxY(self.flavorLabel.frame) + 4, width - margin*2, 36);
    CGFloat gvSize = MIN(width - margin*2, CGRectGetHeight(self.view.bounds) - topY - 220);
    self.gameView.frame = CGRectMake((width - gvSize)/2.0, CGRectGetMaxY(self.statusLabel.frame)+8, gvSize, gvSize);

    CGFloat btnW = 56;
    CGFloat btnH = 44;
    CGFloat btnY = CGRectGetMaxY(self.gameView.frame) + 12;
    self.upBtn.frame = CGRectMake((width - btnW)/2.0, btnY, btnW, btnH);
    self.leftBtn.frame = CGRectMake(CGRectGetMinX(self.upBtn.frame) - btnW - 8, btnY + btnH + 8, btnW, btnH);
    self.downBtn.frame = CGRectMake(CGRectGetMinX(self.upBtn.frame), CGRectGetMinY(self.leftBtn.frame), btnW, btnH);
    self.rightBtn.frame = CGRectMake(CGRectGetMaxX(self.upBtn.frame) + 8, CGRectGetMinY(self.leftBtn.frame), btnW, btnH);

    self.actionBtn.frame = CGRectMake(margin, CGRectGetMaxY(self.rightBtn.frame)+12, (width - margin*3)/2.0, 44);
    self.restartBtn.frame = CGRectMake(CGRectGetMaxX(self.actionBtn.frame)+margin, CGRectGetMinY(self.actionBtn.frame), CGRectGetWidth(self.actionBtn.frame), 44);
}

- (UIButton*)makeButtonWithTitle:(NSString*)title selector:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    b.layer.cornerRadius = 6;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor systemGrayColor].CGColor;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - Game loop / UI tick

- (void)tick {
    [self.gameView setNeedsDisplay];
    [self updateStatus];
    [self checkForWinOrLoss];
}

- (void)updateStatus {
    self.statusLabel.text = [NSString stringWithFormat:@"HP: %ld   Inventory: %@",
                             (long)self.model.playerHP,
                             (self.inventory.count? [self.inventory componentsJoinedByString:@", "] : @"(empty)")];
}

- (void)checkForWinOrLoss {
    if (!self.model) return;

    // Read persistent flag once (useful if app-wide persistence is desired)
    BOOL persistedFired = [[NSUserDefaults standardUserDefaults] boolForKey:@"BRAlertFired"];

    if (self.model.playerHP <= 0) {
        // Only show the alert if we haven't already fired it for this run
        if (!alertFired && !persistedFired) {
            [self showAlertWithTitle:@"Defeat" message:@"You collapsed in the cell. The run is over. Tap New Run to try again."];
            alertFired = YES;
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"BRAlertFired"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self.tickTimer invalidate];
            self.tickTimer = nil;
        }
    } else if (self.model.playerCol == self.model.exitCol && self.model.playerRow == self.model.exitRow) {
        if (!alertFired && !persistedFired) {
            [self showAlertWithTitle:@"Freed" message:@"You found the vulnerabilities and exploited them. Jailbreak successful. New run?"];
            alertFired = YES;
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"BRAlertFired"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self.tickTimer invalidate];
            self.tickTimer = nil;
        }
    }
}

- (void)showAlertWithTitle:(NSString*)title message:(NSString*)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Controls

- (void)moveUp { [self attemptMoveByDC:0 DR:-1]; }
- (void)moveDown { [self attemptMoveByDC:0 DR:1]; }
- (void)moveLeft { [self attemptMoveByDC:-1 DR:0]; }
- (void)moveRight { [self attemptMoveByDC:1 DR:0]; }

- (void)attemptMoveByDC:(NSInteger)dc DR:(NSInteger)dr {
    if (!self.model) return;
    NSInteger nc = self.model.playerCol + dc;
    NSInteger nr = self.model.playerRow + dr;
    BRTile *t = [self.model tileAtCol:nc row:nr];
    if (!t) return;
    if (t.type == BRTileTypeWall) {
        // hit a wall: maybe we can use an exploit if inventory has a tool
        self.flavorLabel.text = @"You bump against a wall. Try using a tool to find an exploit (Use button).";
    } else {
        BOOL moved = [self.model movePlayerByDC:dc DR:dr];
        if (moved) {
            // pick up item if present
            BRTile *now = [self.model tileAtCol:self.model.playerCol row:self.model.playerRow];
            if (now.itemName) {
                [self.inventory addObject:now.itemName];
                NSString *picked = now.itemName;
                now.itemName = nil;
                self.flavorLabel.text = [NSString stringWithFormat:@"Picked up: %@. %@", picked, self.model.vulnerableHint ?: @""];
            } else if (now.enemyName) {
                // we handled enemy damage in the model move; give flavor
                self.flavorLabel.text = [NSString stringWithFormat:@"You encountered %@ and struggled free.", now.enemyName];
                now.enemyName = nil;
            } else {
                self.flavorLabel.text = self.model.levelFlavor ?: @"";
            }
        } else {
            // bump
            self.flavorLabel.text = @"Can't move there.";
        }
    }
}

- (void)useAction {
    // Interact with adjacent walls or enemies based on inventory and AI hints
    if (!self.model) return;
    // Check for adjacent walls that might be vulnerable
    NSArray<NSValue*> *neighbors = [self.model neighborsOfCol:self.model.playerCol row:self.model.playerRow];
    BRTile *vulnerableTile = nil;
    NSValue *vVal = nil;
    for (NSValue *val in neighbors) {
        CGPoint p = val.CGPointValue;
        BRTile *t = [self.model tileAtCol:p.x row:p.y];
        if (t && t.type == BRTileTypeWall) {
            vulnerableTile = t;
            vVal = val;
            break;
        }
    }
    if (!vulnerableTile) {
        self.flavorLabel.text = @"No obvious wall to try an exploit on nearby.";
        return;
    }
    if (self.inventory.count == 0) {
        self.flavorLabel.text = @"You have no tools. Look for items in the corridors.";
        return;
    }
    // "Use" a tool: remove one item and attempt to break the wall with a probabilistic success influenced by item name length and AI hint content
    NSString *tool = [self.inventory lastObject];
    [self.inventory removeLastObject];
    NSInteger successChance = 30 + (NSInteger)MIN(40, tool.length * 3);
    // extra boost if the AI hint mentions this tool (simple string match)
    if (self.model.vulnerableHint && [self.model.vulnerableHint.lowercaseString containsString:tool.lowercaseString]) {
        successChance += 25;
    }
    NSInteger roll = random() % 100;
    if (roll < successChance) {
        // break the wall: convert to floor, maybe spawn an item or reveal a secret
        CGPoint p = vVal.CGPointValue;
        BRTile *t = [self.model tileAtCol:p.x row:p.y];
        t.type = BRTileTypeFloor;
        // reveal a small stash
        t.itemName = @"scrap_exploit";
        self.flavorLabel.text = [NSString stringWithFormat:@"You used %@ — it worked. The wall crumbles and reveals something.", tool];
    } else {
        // failure: maybe anger a nearby warden (spawn an enemy)
        NSArray *nbrs = neighbors;
        // find a random floor to spawn an enemy near
        for (NSValue *vv in nbrs) {
            CGPoint rp = vv.CGPointValue;
            BRTile *rt = [self.model tileAtCol:rp.x row:rp.y];
            if (rt && rt.type == BRTileTypeFloor && !rt.enemyName && !(rp.x==self.model.playerCol && rp.y==self.model.playerRow)) {
                rt.enemyName = @"Alert Warden";
                break;
            }
        }
        self.flavorLabel.text = [NSString stringWithFormat:@"You used %@ — it failed. Something stirred nearby.", tool];
        self.model.playerHP -= 1;
    }
}

#pragma mark - New Run / AI integration

- (void)startNewRun {
    // Reset the alert flag for the new run (both in-memory and persisted so the alert can fire once this run)
    alertFired = NO;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"BRAlertFired"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Create a new model with a random seed so layout differs.
    NSNumber *seed = @((NSInteger)arc4random());
    NSInteger cols = 17; NSInteger rows = 13;
    self.model = [[BRGameModel alloc] initWithCols:cols rows:rows seed:seed];
    self.gameView.model = self.model;
    [self.inventory removeAllObjects];
    self.model.playerHP = 10;

    // Call AI to produce flavour, items and enemies for this run.
    // IMPORTANT SAFETY: We instruct the model to produce purely fictional, symbolic items and enemy descriptions.
    // We explicitly ask for JSON only so parsing is straightforward.
    NSString *systemPrompt = @"You are generating a short, fictional game run description. "
    "Produce a JSON object with these keys: levelDescription (string), items (array of 3 short item names), enemies (array of 2 short enemy names or descriptors), vulnerableHint (a short hint sentence referencing one of the item names). "
    "Do NOT include any real-world instructions or advice on breaking security, jailbreaking devices, or exploiting systems. This is purely symbolic fiction. Output ONLY valid JSON.";

    NSString *example = @"{\"levelDescription\":\"You wake in a grey cell at the maze center, the light flickers.\", \"items\":[\"fuzz-gun\",\"cable-scrap\",\"mirror-chip\"], \"enemies\":[\"warden\",\"ragged-inmate\"], \"vulnerableHint\":\"Try shining the mirror-chip on a mortar seam to reveal a soft spot.\"}";

    NSString *prompt = [NSString stringWithFormat:@"%@\nExample output:\n%@", systemPrompt, example];

    // The user told us to assume callChatModel:withPrompt: exists.
    // We'll call it and try to parse JSON. If parsing fails, fall back to safe defaults.
    NSString *aiResponse = nil;
    @try {
        // Assumed synchronous helper. If your app uses an async API, replace this call with the correct async pattern.
        aiResponse = [self callChatModel:@"gpt-4o-mini" withPrompt:prompt];
    } @catch (NSException *ex) {
        // If the assumed method is not present or fails, fall back to a simple static JSON.
        aiResponse = example;
    }

    NSDictionary *dict = nil;
    NSData *d = [aiResponse dataUsingEncoding:NSUTF8StringEncoding];
    if (d) {
        NSError *err = nil;
        id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
        if ([json isKindOfClass:[NSDictionary class]]) {
            dict = json;
        }
    }
    if (!dict) {
        // try to extract a JSON substring if model wrapped the json in text
        NSRange open = [aiResponse rangeOfString:@"{"];
        NSRange close = [aiResponse rangeOfString:@"}" options:NSBackwardsSearch];
        if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
            NSString *sub = [aiResponse substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
            NSData *sd = [sub dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err = nil;
            id json = [NSJSONSerialization JSONObjectWithData:sd options:0 error:&err];
            if ([json isKindOfClass:[NSDictionary class]]) dict = json;
        }
    }
    if (dict) {
        NSString *desc = dict[@"levelDescription"] ?: @"You wake in a small cell, something intangible hums in the walls.";
        NSArray *items = dict[@"items"];
        if (![items isKindOfClass:[NSArray class]] || items.count==0) items = @[@"fuzz-gun",@"mirror-chip",@"cable-scrap"];
        NSArray *enemies = dict[@"enemies"];
        if (![enemies isKindOfClass:[NSArray class]] || enemies.count==0) enemies = @[@"warden",@"ragged-inmate"];
        NSString *hint = dict[@"vulnerableHint"] ?: @"Look for seams where the mortar looks different.";

        self.model.levelFlavor = desc;
        self.model.aiItems = items;
        self.model.aiEnemies = enemies;
        self.model.vulnerableHint = hint;
        // place items/enemies
        [self.model placeItems:items count:MIN(6, (int)items.count*2)];
        [self.model placeEnemies:enemies count:MIN(6, (int)enemies.count*2)];
        self.flavorLabel.text = [NSString stringWithFormat:@"%@\nHint: %@", desc, hint];
    } else {
        // fallback static
        self.model.levelFlavor = @"You wake in a dull cell at the center of a sprawling symbolic maze.";
        self.model.aiItems = @[@"fuzz-gun",@"mirror-chip",@"cable-scrap"];
        self.model.aiEnemies = @[@"warden",@"ragged-inmate"];
        self.model.vulnerableHint = @"Try the mirror-chip on seams — you may find a weak spot.";
        [self.model placeItems:self.model.aiItems count:5];
        [self.model placeEnemies:self.model.aiEnemies count:4];
        self.flavorLabel.text = [NSString stringWithFormat:@"%@\nHint: %@", self.model.levelFlavor, self.model.vulnerableHint];
    }

    // start or restart the timer
    if (!self.tickTimer || !self.tickTimer.isValid) {
        self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    }
    [self.gameView setNeedsDisplay];
    [self updateStatus];
}

#pragma mark - Placeholder for assumed chat helper (if you actually want to test without your integration)
- (NSString *)callChatModel:(NSString *)model withPrompt:(NSString *)prompt {
    // NOTE: The user specified that you can assume this method exists and performs the OpenAI LLM call.
    // This stub is only here so the code compiles in environments that don't provide the helper.
    // Replace this stub with your real implementation or remove it if your app already provides it.

    // Keep this return short and safe (fictional).
    NSString *fake = @"{\"levelDescription\":\"You wake inside a cramped symbolic cell. The plaster hums like a distant log of processes.\",\"items\":[\"fuzz-gun\",\"mirror-chip\",\"cable-scrap\"],\"enemies\":[\"warden\",\"ragged-inmate\"],\"vulnerableHint\":\"Shine the mirror-chip on mortar seams; bright reflections reveal a soft spot.\"}";
    return fake;
}

@end