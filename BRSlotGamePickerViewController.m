// BRSlotGamePickerViewController.m
// EZCompleteUI
//
// Purpose:
//   The casino lobby: a scrolling grid of cards, one per slot machine (plus VIP
//   variants, the custom-game creator, community games and saved games) and the
//   blackjack tables. Tapping a card pushes that game's screen. Also hosts the
//   shared lounge chat bar, profile and winners board entry points.
//
// Changes (blackjack tables):
//   - Added a "Blackjack" card after Community that opens
//     BRBlackjackLobbyViewController. The fixed-card count went from 14 to 15,
//     so saved-game indexes now start at 15.

#import "BRSlotGamePickerViewController.h"
#import "BRSlotMachineViewController.h"
#import "BRPennySlotViewController.h"
#import "BRPlunderBayViewController.h"
#import "BRGoldenMandarinSlotViewController.h"
#import "BRGoldenMandarinArt.h"
#import "BRPhoenixPavilionSlotViewController.h"
#import "BRPhoenixPavilionArt.h"
#import "BRStarlightOdysseySlotViewController.h"
#import "BRStarlightOdysseyArt.h"
#import "BRPenguinParadeSlotViewController.h"
#import "BRPenguinParadeArt.h"
#import "BRGameLibrary.h"
#import "BRGamePickerViewController.h"
#import "BRSlotChatBar.h"
#import "BRBlackjackLobbyViewController.h"
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, BRSlotPickerCardKind) { BRSlotPickerCardKindClassic, BRSlotPickerCardKindPenny, BRSlotPickerCardKindPlunder, BRSlotPickerCardKindPlunderVIP, BRSlotPickerCardKindGolden, BRSlotPickerCardKindGoldenVIP, BRSlotPickerCardKindPhoenix, BRSlotPickerCardKindPhoenixVIP, BRSlotPickerCardKindStarlight, BRSlotPickerCardKindStarlightVIP, BRSlotPickerCardKindPenguin, BRSlotPickerCardKindPenguinVIP, BRSlotPickerCardKindCreate, BRSlotPickerCardKindCommunity, BRSlotPickerCardKindBlackjack, BRSlotPickerCardKindSaved };

@interface BRSlotPickerCard : UICollectionViewCell
- (void)configureWithTitle:(NSString *)title premise:(NSString *)premise image:(UIImage *)image kind:(BRSlotPickerCardKind)kind;
@end

@implementation BRSlotPickerCard {
    UIImageView *_art, *_fallbackIcon;
    UIView *_artFallback;
    UILabel *_titleLabel, *_premiseLabel;
    CAGradientLayer *_sceneGradient;
    UIView *_glowView;
    CAGradientLayer *_glowLayer;
    UIView *_decorView;
    UIView *_vipBadge;
    CAGradientLayer *_vipGradient;
    UILabel *_vipLabel;
    UIView *_playPill;
    CAGradientLayer *_playGradient;
    UILabel *_playLabel;
    UIImageView *_playChevron;
    BRSlotPickerCardKind _kind;
    BOOL _hasKind;
    CGSize _decorSize;
}

// Scene colours are derived from the per-kind base colour configure
// already picks: lightened toward white for the top of the scene,
// darkened for the bottom, so every card keeps its own palette.
static UIColor *BRSlotPickerLighten(UIColor *color, CGFloat amount) {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return color;
    return [UIColor colorWithRed:r + (1 - r) * amount green:g + (1 - g) * amount blue:b + (1 - b) * amount alpha:a];
}
static UIColor *BRSlotPickerDarken(UIColor *color, CGFloat amount) {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return color;
    CGFloat scale = 1 - amount;
    return [UIColor colorWithRed:r * scale green:g * scale blue:b * scale alpha:a];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = .32;
    self.layer.shadowRadius = 10;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:.05];
    self.contentView.layer.cornerRadius = 18;
    self.contentView.layer.borderWidth = 1;
    self.contentView.layer.borderColor = [UIColor colorWithWhite:1 alpha:.16].CGColor;
    self.contentView.clipsToBounds = YES;

    _art = [UIImageView new];
    _art.contentMode = UIViewContentModeScaleAspectFill;
    _art.clipsToBounds = YES;
    _art.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_art];

    _artFallback = [UIView new];
    _artFallback.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_artFallback];
    _sceneGradient = [CAGradientLayer layer];
    _sceneGradient.startPoint = CGPointMake(.5, 0);
    _sceneGradient.endPoint = CGPointMake(.5, 1);
    [_artFallback.layer insertSublayer:_sceneGradient atIndex:0];
    _glowView = [UIView new];
    _glowView.userInteractionEnabled = NO;
    _glowView.translatesAutoresizingMaskIntoConstraints = NO;
    [_artFallback addSubview:_glowView];
    _glowLayer = [CAGradientLayer layer];
    _glowLayer.type = kCAGradientLayerRadial;
    _glowLayer.startPoint = CGPointMake(.5, .5);
    _glowLayer.endPoint = CGPointMake(1, 1);
    [_glowView.layer addSublayer:_glowLayer];
    _decorView = [UIView new];
    _decorView.userInteractionEnabled = NO;
    _decorView.translatesAutoresizingMaskIntoConstraints = NO;
    [_artFallback addSubview:_decorView];
    _fallbackIcon = [UIImageView new];
    _fallbackIcon.contentMode = UIViewContentModeScaleAspectFit;
    _fallbackIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [_artFallback addSubview:_fallbackIcon];

    _vipBadge = [UIView new];
    _vipBadge.layer.cornerRadius = 8;
    _vipBadge.layer.masksToBounds = YES;
    _vipBadge.userInteractionEnabled = NO;
    _vipBadge.hidden = YES;
    _vipBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_vipBadge];
    _vipGradient = [CAGradientLayer layer];
    _vipGradient.colors = @[(id)[UIColor colorWithRed:1 green:.85 blue:.30 alpha:1].CGColor, (id)[UIColor colorWithRed:.90 green:.60 blue:.07 alpha:1].CGColor];
    _vipGradient.startPoint = CGPointMake(0, 0);
    _vipGradient.endPoint = CGPointMake(0, 1);
    [_vipBadge.layer insertSublayer:_vipGradient atIndex:0];
    _vipLabel = [UILabel new];
    _vipLabel.text = @"VIP";
    _vipLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBlack];
    _vipLabel.textColor = [UIColor colorWithRed:.25 green:.16 blue:.02 alpha:1];
    _vipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_vipBadge addSubview:_vipLabel];

    _titleLabel = [UILabel new];
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.5;
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBlack];
    _titleLabel.numberOfLines = 2;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_titleLabel];

    _premiseLabel = [UILabel new];
    _premiseLabel.textColor = [UIColor colorWithWhite:.72 alpha:1];
    _premiseLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _premiseLabel.numberOfLines = 0;
    _premiseLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_premiseLabel];

    // The PLAY pill is decoration: the whole card stays the tap
    // target, exactly as before, so the pill never takes touches.
    _playPill = [UIView new];
    _playPill.layer.cornerRadius = 13;
    _playPill.layer.masksToBounds = YES;
    _playPill.layer.borderWidth = 1;
    _playPill.layer.borderColor = [UIColor colorWithWhite:1 alpha:.30].CGColor;
    _playPill.userInteractionEnabled = NO;
    _playPill.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_playPill];
    _playGradient = [CAGradientLayer layer];
    _playGradient.startPoint = CGPointMake(0, 0);
    _playGradient.endPoint = CGPointMake(0, 1);
    [_playPill.layer insertSublayer:_playGradient atIndex:0];
    _playLabel = [UILabel new];
    _playLabel.text = NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Play", nil, NSBundle.mainBundle, @"PLAY", nil);
    _playLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBlack];
    _playLabel.textColor = UIColor.whiteColor;
    _playLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_playPill addSubview:_playLabel];
    _playChevron = [UIImageView new];
    _playChevron.image = [UIImage systemImageNamed:@"chevron.right"];
    _playChevron.contentMode = UIViewContentModeScaleAspectFit;
    _playChevron.tintColor = UIColor.whiteColor;
    _playChevron.translatesAutoresizingMaskIntoConstraints = NO;
    [_playPill addSubview:_playChevron];

    // The premise sits directly above the Play pill and the art area
    // takes whatever height the text does not need, so short cards show
    // no dead gap under the premise. Non-required so an unusually long
    // premise degrades to the old bottom-capped layout instead of
    // breaking constraints.
    NSLayoutConstraint *premiseAbovePill = [_premiseLabel.bottomAnchor constraintEqualToAnchor:_playPill.topAnchor constant:-8];
    premiseAbovePill.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [_art.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_art.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_art.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_art.heightAnchor constraintGreaterThanOrEqualToConstant:80],
        [_artFallback.topAnchor constraintEqualToAnchor:_art.topAnchor],
        [_artFallback.leadingAnchor constraintEqualToAnchor:_art.leadingAnchor],
        [_artFallback.trailingAnchor constraintEqualToAnchor:_art.trailingAnchor],
        [_artFallback.bottomAnchor constraintEqualToAnchor:_art.bottomAnchor],
        [_glowView.topAnchor constraintEqualToAnchor:_artFallback.topAnchor],
        [_glowView.leadingAnchor constraintEqualToAnchor:_artFallback.leadingAnchor],
        [_glowView.trailingAnchor constraintEqualToAnchor:_artFallback.trailingAnchor],
        [_glowView.bottomAnchor constraintEqualToAnchor:_artFallback.bottomAnchor],
        [_decorView.topAnchor constraintEqualToAnchor:_artFallback.topAnchor],
        [_decorView.leadingAnchor constraintEqualToAnchor:_artFallback.leadingAnchor],
        [_decorView.trailingAnchor constraintEqualToAnchor:_artFallback.trailingAnchor],
        [_decorView.bottomAnchor constraintEqualToAnchor:_artFallback.bottomAnchor],
        [_fallbackIcon.centerXAnchor constraintEqualToAnchor:_artFallback.centerXAnchor],
        [_fallbackIcon.centerYAnchor constraintEqualToAnchor:_artFallback.centerYAnchor],
        [_fallbackIcon.widthAnchor constraintEqualToAnchor:_artFallback.heightAnchor multiplier:.52],
        [_fallbackIcon.heightAnchor constraintEqualToAnchor:_artFallback.heightAnchor multiplier:.52],
        [_vipBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [_vipBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        [_vipBadge.heightAnchor constraintEqualToConstant:16],
        [_vipLabel.leadingAnchor constraintEqualToAnchor:_vipBadge.leadingAnchor constant:6],
        [_vipLabel.trailingAnchor constraintEqualToAnchor:_vipBadge.trailingAnchor constant:-6],
        [_vipLabel.centerYAnchor constraintEqualToAnchor:_vipBadge.centerYAnchor],
        [_titleLabel.topAnchor constraintEqualToAnchor:_art.bottomAnchor constant:10],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [_premiseLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
        [_premiseLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_premiseLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        premiseAbovePill,
        [_playPill.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [_playPill.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [_playPill.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        [_playPill.heightAnchor constraintEqualToConstant:26],
        [_playLabel.centerYAnchor constraintEqualToAnchor:_playPill.centerYAnchor],
        [_playLabel.centerXAnchor constraintEqualToAnchor:_playPill.centerXAnchor constant:-7],
        [_playChevron.leadingAnchor constraintEqualToAnchor:_playLabel.trailingAnchor constant:3],
        [_playChevron.centerYAnchor constraintEqualToAnchor:_playPill.centerYAnchor],
        [_playChevron.widthAnchor constraintEqualToConstant:8],
        [_playChevron.heightAnchor constraintEqualToConstant:12],
    ]];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _sceneGradient.frame = _artFallback.bounds;
    CGFloat glowDiameter = CGRectGetHeight(_glowView.bounds) * 1.15;
    _glowLayer.frame = CGRectMake((CGRectGetWidth(_glowView.bounds) - glowDiameter) / 2,
                                  (CGRectGetHeight(_glowView.bounds) - glowDiameter) / 2,
                                  glowDiameter, glowDiameter);
    _vipGradient.frame = _vipBadge.bounds;
    _playGradient.frame = _playPill.bounds;
    if (_hasKind && CGRectGetWidth(_artFallback.bounds) > 0 &&
        !CGSizeEqualToSize(_decorSize, _artFallback.bounds.size)) {
        _decorSize = _artFallback.bounds.size;
        [self rebuildDecor];
    }
}

- (void)addDecorDotAtX:(CGFloat)fx y:(CGFloat)fy size:(CGFloat)size color:(UIColor *)color {
    CGFloat w = CGRectGetWidth(_decorView.bounds), h = CGRectGetHeight(_decorView.bounds);
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(fx * w - size / 2, fy * h - size / 2, size, size)];
    dot.layer.cornerRadius = size / 2;
    dot.backgroundColor = color;
    dot.userInteractionEnabled = NO;
    [_decorView addSubview:dot];
}

- (void)addDecorSparkleAtX:(CGFloat)fx y:(CGFloat)fy size:(CGFloat)size color:(UIColor *)color {
    CGFloat w = CGRectGetWidth(_decorView.bounds), h = CGRectGetHeight(_decorView.bounds);
    UIView *sparkle = [[UIView alloc] initWithFrame:CGRectMake(fx * w - size / 2, fy * h - size / 2, size, size)];
    sparkle.layer.cornerRadius = 1.5;
    sparkle.backgroundColor = color;
    sparkle.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_4);
    sparkle.userInteractionEnabled = NO;
    [_decorView addSubview:sparkle];
}

// Small drawn accents over the scene, picked per theme: stars for
// Starlight, sparkles for Golden and Phoenix, snow for Penguin,
// coins for Plunder, soft dots for the rest. A handful of tiny
// views per card, rebuilt only when the card changes size or kind.
- (void)rebuildDecor {
    for (UIView *sub in [_decorView.subviews copy]) [sub removeFromSuperview];
    if (CGRectGetWidth(_decorView.bounds) <= 0) return;
    UIColor *white = UIColor.whiteColor;
    UIColor *gold = [UIColor colorWithRed:1 green:.80 blue:.25 alpha:1];
    switch (_kind) {
        case BRSlotPickerCardKindStarlight:
        case BRSlotPickerCardKindStarlightVIP:
            [self addDecorDotAtX:.12 y:.20 size:3 color:[white colorWithAlphaComponent:.9]];
            [self addDecorDotAtX:.85 y:.16 size:2.5 color:[white colorWithAlphaComponent:.8]];
            [self addDecorDotAtX:.70 y:.75 size:2 color:[white colorWithAlphaComponent:.6]];
            [self addDecorDotAtX:.20 y:.80 size:2.5 color:[white colorWithAlphaComponent:.7]];
            [self addDecorDotAtX:.92 y:.55 size:3 color:[white colorWithAlphaComponent:.85]];
            [self addDecorDotAtX:.35 y:.12 size:2 color:[white colorWithAlphaComponent:.6]];
            [self addDecorSparkleAtX:.78 y:.35 size:7 color:gold];
            [self addDecorSparkleAtX:.15 y:.50 size:6 color:[white colorWithAlphaComponent:.85]];
            break;
        case BRSlotPickerCardKindGolden:
        case BRSlotPickerCardKindGoldenVIP:
        case BRSlotPickerCardKindPhoenix:
        case BRSlotPickerCardKindPhoenixVIP:
            [self addDecorSparkleAtX:.14 y:.22 size:7 color:[gold colorWithAlphaComponent:.95]];
            [self addDecorSparkleAtX:.86 y:.30 size:6 color:[gold colorWithAlphaComponent:.9]];
            [self addDecorSparkleAtX:.72 y:.78 size:5 color:[gold colorWithAlphaComponent:.85]];
            [self addDecorDotAtX:.30 y:.70 size:3 color:[gold colorWithAlphaComponent:.5]];
            [self addDecorDotAtX:.90 y:.65 size:2.5 color:[gold colorWithAlphaComponent:.5]];
            [self addDecorDotAtX:.50 y:.14 size:2.5 color:[gold colorWithAlphaComponent:.45]];
            break;
        case BRSlotPickerCardKindPenguin:
        case BRSlotPickerCardKindPenguinVIP:
            [self addDecorDotAtX:.10 y:.18 size:4 color:[white colorWithAlphaComponent:.7]];
            [self addDecorDotAtX:.30 y:.35 size:3 color:[white colorWithAlphaComponent:.5]];
            [self addDecorDotAtX:.55 y:.15 size:5 color:[white colorWithAlphaComponent:.6]];
            [self addDecorDotAtX:.80 y:.28 size:3 color:[white colorWithAlphaComponent:.55]];
            [self addDecorDotAtX:.90 y:.60 size:4 color:[white colorWithAlphaComponent:.45]];
            [self addDecorDotAtX:.18 y:.72 size:3 color:[white colorWithAlphaComponent:.4]];
            [self addDecorDotAtX:.65 y:.80 size:4 color:[white colorWithAlphaComponent:.5]];
            [self addDecorDotAtX:.42 y:.60 size:2.5 color:[white colorWithAlphaComponent:.45]];
            break;
        case BRSlotPickerCardKindPlunder:
        case BRSlotPickerCardKindPlunderVIP:
            [self addDecorDotAtX:.14 y:.25 size:6 color:[gold colorWithAlphaComponent:.85]];
            [self addDecorDotAtX:.86 y:.20 size:5 color:[gold colorWithAlphaComponent:.8]];
            [self addDecorDotAtX:.75 y:.75 size:6 color:[gold colorWithAlphaComponent:.7]];
            [self addDecorDotAtX:.25 y:.80 size:4 color:[gold colorWithAlphaComponent:.6]];
            break;
        default:
            [self addDecorDotAtX:.15 y:.25 size:4 color:[white colorWithAlphaComponent:.16]];
            [self addDecorDotAtX:.85 y:.30 size:3 color:[white colorWithAlphaComponent:.16]];
            [self addDecorDotAtX:.70 y:.75 size:4 color:[white colorWithAlphaComponent:.16]];
            [self addDecorDotAtX:.30 y:.80 size:3 color:[white colorWithAlphaComponent:.16]];
            break;
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _art.image = nil;
    _art.hidden = NO;
    _artFallback.hidden = NO;
    _titleLabel.textColor = UIColor.whiteColor;
    _vipBadge.hidden = YES;
    _hasKind = NO;
    _decorSize = CGSizeZero;
    for (UIView *sub in [_decorView.subviews copy]) [sub removeFromSuperview];
    self.contentView.layer.borderWidth = 1;
    self.contentView.layer.borderColor = [UIColor colorWithWhite:1 alpha:.16].CGColor;
    self.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:.05];
}

- (void)configureWithTitle:(NSString *)title premise:(NSString *)premise image:(UIImage *)image kind:(BRSlotPickerCardKind)kind {
    _kind = kind;
    _hasKind = YES;
    _titleLabel.text = title;
    _premiseLabel.text = premise;
    _art.image = image;
    _art.hidden = (image == nil);
    _artFallback.hidden = (image != nil);
    UIColor *color = kind == BRSlotPickerCardKindBlackjack ? [UIColor colorWithRed:.03 green:.30 blue:.17 alpha:1] : (kind == BRSlotPickerCardKindPenguinVIP || kind == BRSlotPickerCardKindGoldenVIP || kind == BRSlotPickerCardKindPhoenixVIP || kind == BRSlotPickerCardKindStarlightVIP) ? [UIColor colorWithRed:.17 green:.12 blue:.03 alpha:1] : kind == BRSlotPickerCardKindPenguin ? [UIColor colorWithRed:.05 green:.26 blue:.45 alpha:1] : kind == BRSlotPickerCardKindStarlight ? [UIColor colorWithRed:.08 green:.07 blue:.30 alpha:1] : kind == BRSlotPickerCardKindPhoenix ? [UIColor colorWithRed:.04 green:.23 blue:.27 alpha:1] : kind == BRSlotPickerCardKindGolden ? [UIColor colorWithRed:.42 green:.04 blue:.07 alpha:1] : kind == BRSlotPickerCardKindPlunder ? [UIColor colorWithRed:.04 green:.09 blue:.22 alpha:1] : kind == BRSlotPickerCardKindPenny ? [UIColor colorWithRed:.20 green:.36 blue:.24 alpha:1] : kind == BRSlotPickerCardKindCommunity ? [UIColor colorWithRed:.23 green:.10 blue:.42 alpha:1] : kind == BRSlotPickerCardKindCreate ? [UIColor colorWithRed:.05 green:.34 blue:.38 alpha:1] : [UIColor colorWithRed:.36 green:.10 blue:.42 alpha:1];
    _artFallback.backgroundColor = color;
    NSString *symbol = kind == BRSlotPickerCardKindBlackjack ? @"suit.spade.fill" : kind == BRSlotPickerCardKindCommunity ? @"person.3.fill" : kind == BRSlotPickerCardKindCreate ? @"paintpalette.fill" : @"7.circle.fill";
    _fallbackIcon.image = kind == BRSlotPickerCardKindPenny ? [UIImage imageNamed:@"EZCoin"] : (kind == BRSlotPickerCardKindGolden || kind == BRSlotPickerCardKindGoldenVIP) ? [BRGoldenMandarinArt imageForSymbol:GMSymbolHat size:CGSizeMake(260, 260)] : (kind == BRSlotPickerCardKindPhoenix || kind == BRSlotPickerCardKindPhoenixVIP) ? [BRPhoenixPavilionArt imageForSymbol:PPSymbolPhoenix size:CGSizeMake(260, 260)] : (kind == BRSlotPickerCardKindStarlight || kind == BRSlotPickerCardKindStarlightVIP) ? [BRStarlightOdysseyArt imageForSymbol:SOSymbolGalaxy size:CGSizeMake(260, 260)] : kind == BRSlotPickerCardKindPenguin ? [BRPenguinParadeArt imageForSymbol:PGSymbolEmperor size:CGSizeMake(260, 260)] : kind == BRSlotPickerCardKindPenguinVIP ? [BRPenguinParadeArt imageForSymbol:PGSymbolEmperor size:CGSizeMake(260, 260)] : (kind == BRSlotPickerCardKindPlunder || kind == BRSlotPickerCardKindPlunderVIP) ? [BRPlunderBayViewController plunderSymbolImage:@"scatter"] : [UIImage systemImageNamed:symbol];
    _fallbackIcon.tintColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1];
    BOOL vip = (kind == BRSlotPickerCardKindPlunderVIP || kind == BRSlotPickerCardKindPenguinVIP || kind == BRSlotPickerCardKindGoldenVIP || kind == BRSlotPickerCardKindPhoenixVIP || kind == BRSlotPickerCardKindStarlightVIP);
    _vipBadge.hidden = !vip;
    if (vip) {
        _artFallback.backgroundColor = [UIColor colorWithRed:.17 green:.12 blue:.03 alpha:1];
        _sceneGradient.colors = @[(id)[UIColor colorWithRed:.40 green:.29 blue:.07 alpha:1].CGColor, (id)[UIColor colorWithRed:.12 green:.08 blue:.02 alpha:1].CGColor];
        _titleLabel.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1];
        self.contentView.layer.borderWidth = 2.5;
        self.contentView.layer.borderColor = [UIColor colorWithRed:1 green:.73 blue:.16 alpha:.95].CGColor;
        self.contentView.backgroundColor = [UIColor colorWithRed:1 green:.85 blue:.3 alpha:.10];
        _playGradient.colors = @[(id)[UIColor colorWithRed:1 green:.80 blue:.20 alpha:1].CGColor, (id)[UIColor colorWithRed:.88 green:.58 blue:.06 alpha:1].CGColor];
        _playLabel.textColor = [UIColor colorWithRed:.23 green:.15 blue:.02 alpha:1];
        _playChevron.tintColor = [UIColor colorWithRed:.23 green:.15 blue:.02 alpha:1];
        _playPill.layer.borderColor = [UIColor colorWithRed:1 green:.73 blue:.16 alpha:.9].CGColor;
    } else {
        _sceneGradient.colors = @[(id)BRSlotPickerLighten(color, .30).CGColor, (id)BRSlotPickerDarken(color, .45).CGColor];
        _playGradient.colors = @[(id)BRSlotPickerLighten(color, .35).CGColor, (id)color.CGColor];
        _playLabel.textColor = UIColor.whiteColor;
        _playChevron.tintColor = UIColor.whiteColor;
        _playPill.layer.borderColor = [UIColor colorWithWhite:1 alpha:.30].CGColor;
    }
    UIColor *glowColor = vip ? [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1] : BRSlotPickerLighten(color, .25);
    _glowLayer.colors = @[(id)[glowColor colorWithAlphaComponent:.50].CGColor, (id)[glowColor colorWithAlphaComponent:0].CGColor];
    _decorSize = CGSizeZero;
    if (CGRectGetWidth(_artFallback.bounds) > 0) {
        _decorSize = _artFallback.bounds.size;
        [self rebuildDecor];
    }
}
@end

// Full-width hero band for the top of the picker: a drawn
// navy-to-purple scene with spotlight glows, sparkles and coins, a
// crown over a gold-gradient title and the letterspaced tagline.
// Everything is CoreGraphics — no image assets.
@interface BRSlotPickerHeroView : UIView
- (instancetype)initWithTitle:(NSString *)title tagline:(NSString *)tagline;
@end

@implementation BRSlotPickerHeroView {
    NSString *_title;
    UIImage *_titleImage;
    CGFloat _titleImageWidth;
    UIImageView *_crownView;
    UILabel *_taglineLabel;
}

- (instancetype)initWithTitle:(NSString *)title tagline:(NSString *)tagline {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _title = [title copy];
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    _crownView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"crown.fill"]];
    _crownView.tintColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1];
    _crownView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_crownView];
    _taglineLabel = [UILabel new];
    _taglineLabel.attributedText = [[NSAttributedString alloc] initWithString:tagline ?: @"" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:.78],
        NSKernAttributeName: @2.4,
    }];
    _taglineLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_taglineLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    _crownView.frame = CGRectMake((w - 30) / 2, 8, 30, 20);
    _taglineLabel.frame = CGRectMake(16, 78, w - 32, 16);
    [self setNeedsDisplay];
}

// The title is rendered once per width so drawRect can use it as a
// mask and wash the gold gradient through the letterforms.
- (UIImage *)titleImageForWidth:(CGFloat)width {
    if (_titleImage && fabs(_titleImageWidth - width) < 1) return _titleImage;
    UILabel *label = [UILabel new];
    label.text = _title;
    label.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBlack];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = .55;
    CGSize size = CGSizeMake(width, 38);
    label.frame = CGRectMake(0, 0, size.width, size.height);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    _titleImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [label.layer renderInContext:context.CGContext];
    }];
    _titleImageWidth = width;
    return _titleImage;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w = CGRectGetWidth(rect), h = CGRectGetHeight(rect);
    // Navy-to-purple wash.
    CGGradientRef wash = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[
        (id)[UIColor colorWithRed:.13 green:.05 blue:.30 alpha:1].CGColor,
        (id)[UIColor colorWithRed:.05 green:.02 blue:.11 alpha:1].CGColor], (CGFloat[]){0, 1});
    CGContextDrawLinearGradient(ctx, wash, CGPointMake(0, 0), CGPointMake(0, h), 0);
    CGGradientRelease(wash);
    // Spotlight glows: gold centre-top, purple at the right edge.
    CGGradientRef goldGlow = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[
        (id)[UIColor colorWithRed:1 green:.78 blue:.18 alpha:.30].CGColor,
        (id)[UIColor colorWithRed:1 green:.78 blue:.18 alpha:0].CGColor], (CGFloat[]){0, 1});
    CGContextDrawRadialGradient(ctx, goldGlow, CGPointMake(w * .5, -30), 0, CGPointMake(w * .5, -30), w * .75, 0);
    CGGradientRelease(goldGlow);
    CGGradientRef purpleGlow = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[
        (id)[UIColor colorWithRed:.55 green:.30 blue:1 alpha:.35].CGColor,
        (id)[UIColor colorWithRed:.55 green:.30 blue:1 alpha:0].CGColor], (CGFloat[]){0, 1});
    CGContextDrawRadialGradient(ctx, purpleGlow, CGPointMake(w * .92, 12), 0, CGPointMake(w * .92, 12), 170, 0);
    CGGradientRelease(purpleGlow);
    // Sparkle dots.
    static const CGFloat dots[][4] = {
        {.08, .30, 2.5, .9}, {.16, .68, 2, .6}, {.88, .26, 2.5, .85}, {.93, .62, 2, .6},
        {.70, .16, 1.8, .7}, {.30, .18, 1.8, .65}, {.62, .82, 2, .5}, {.40, .86, 1.6, .5},
    };
    for (NSUInteger i = 0; i < sizeof(dots) / sizeof(dots[0]); i++) {
        CGFloat r = dots[i][2];
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:dots[i][3]].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(dots[i][0] * w - r, dots[i][1] * h - r, r * 2, r * 2));
    }
    // Two coins: a gold ring with a smaller ring inside.
    const CGFloat coins[][3] = {{.10, .55, 7}, {.90, .45, 6}};
    for (NSUInteger i = 0; i < 2; i++) {
        CGPoint c = CGPointMake(coins[i][0] * w, coins[i][1] * h);
        CGFloat r = coins[i][2];
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:.78 blue:.18 alpha:.9].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, r * 2, r * 2));
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:.78 blue:.18 alpha:.55].CGColor);
        CGContextSetLineWidth(ctx, 1.2);
        CGFloat inner = r * .55;
        CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - inner, c.y - inner, inner * 2, inner * 2));
    }
    // Two four-point sparkles.
    const CGFloat sparkles[][4] = {{.22, .40, 5, .95}, {.80, .72, 4, .8}};
    for (NSUInteger i = 0; i < 2; i++) {
        CGPoint c = CGPointMake(sparkles[i][0] * w, sparkles[i][1] * h);
        CGFloat s = sparkles[i][2];
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1 green:.82 blue:.30 alpha:sparkles[i][3]].CGColor);
        CGContextMoveToPoint(ctx, c.x, c.y - s);
        CGContextAddQuadCurveToPoint(ctx, c.x, c.y, c.x + s, c.y);
        CGContextAddQuadCurveToPoint(ctx, c.x, c.y, c.x, c.y + s);
        CGContextAddQuadCurveToPoint(ctx, c.x, c.y, c.x - s, c.y);
        CGContextAddQuadCurveToPoint(ctx, c.x, c.y, c.x, c.y - s);
        CGContextFillPath(ctx);
    }
    // Gold-gradient title, clipped through the rendered letterforms.
    UIImage *titleImage = [self titleImageForWidth:w];
    CGRect titleRect = CGRectMake(0, 34, w, 38);
    CGContextSaveGState(ctx);
    // ClipToMask reads the mask in Core Graphics' bottom-left space,
    // which lands the letterforms upside down in this flipped UIKit
    // context. Flip the context around the title rect while clipping,
    // then flip back — a clip, once set, is not moved by later
    // transform changes, so the gradient below draws normally.
    CGFloat flipSpan = CGRectGetMinY(titleRect) + CGRectGetMaxY(titleRect);
    CGContextTranslateCTM(ctx, 0, flipSpan);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextClipToMask(ctx, titleRect, titleImage.CGImage);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextTranslateCTM(ctx, 0, -flipSpan);
    CGGradientRef gold = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[
        (id)[UIColor colorWithRed:1 green:.93 blue:.48 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:.74 blue:.14 alpha:1].CGColor,
        (id)[UIColor colorWithRed:.83 green:.48 blue:.03 alpha:1].CGColor], (CGFloat[]){0, .55, 1});
    CGContextDrawLinearGradient(ctx, gold, CGPointMake(0, 34), CGPointMake(0, 72), 0);
    CGGradientRelease(gold);
    CGContextRestoreGState(ctx);
}
@end


@interface BRSlotGamePickerViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic,strong) UICollectionView *collectionView;
@property (nonatomic,strong) CAGradientLayer *backgroundGradient;
@property (nonatomic,strong) CAGradientLayer *backgroundGlow;
@property (nonatomic, strong) AVAudioEngine *casinoEngine;
@property (nonatomic, strong) AVAudioPlayerNode *casinoNode;
@property (nonatomic, strong) AVAudioPCMBuffer *casinoBuffer;
@property (nonatomic,strong) NSArray<BRGameRecord *> *importableGames;
@property (nonatomic, strong) BRSlotChatBar *loungeHelper; // never attached or started: owns the winners-board and profile flows for the buttons in the nav bar
@property (nonatomic, strong) UIButton *profileAvatarButton; // the nav-bar profile button; shows the player's photo once they have one
@property (nonatomic, strong) UIButton *soundButton; // the nav-bar slot sound on/off toggle
@end

@implementation BRSlotGamePickerViewController
- (void)setupCasinoAmbience {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"caf" subdirectory:@"sounds"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"caf"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"mp3" subdirectory:@"sounds"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"mp3"];
    if (url) {
        // Gapless loop: decode the file to a PCM buffer on a player
        // node. AVAudioPlayer looping replays a compressed file's
        // priming/padding samples as a silence gap at every wrap; a
        // PCM buffer scheduled with BufferLoops loops sample-accurately.
        // Same rule as the machines: a bad sound file stays silent,
        // it never crashes the picker (AVAudioFile throws on some
        // corrupt/mislabeled inputs where AVAudioPlayer returned nil).
        @try {
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:nil];
        AVAudioFormat *format = file.processingFormat;
        if (file && file.length > 0 && format && format.sampleRate > 0 && format.channelCount > 0) {
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)file.length];
            if (buffer && [file readIntoBuffer:buffer error:nil] && buffer.frameLength > 0) {
                // Trim a zero-padded decode tail (VBR length overstate,
                // as in the machines' loop builder). No-op when the
                // file's tail is real audio.
                if (buffer.format.commonFormat == AVAudioPCMFormatFloat32 && !buffer.format.interleaved && buffer.floatChannelData) {
                    AVAudioFrameCount frames = buffer.frameLength;
                    float * const *channels = buffer.floatChannelData;
                    NSUInteger channelCount = buffer.format.channelCount;
                    while (frames > 0) {
                        BOOL silent = YES;
                        for (NSUInteger c = 0; c < channelCount; c++) {
                            if (fabsf(channels[c][frames - 1]) > 0.0005f) { silent = NO; break; }
                        }
                        if (!silent) break;
                        frames--;
                    }
                    buffer.frameLength = frames;
                }
            }
            if (buffer && buffer.frameLength > 0) {
                self.casinoBuffer = buffer;
                self.casinoEngine = [AVAudioEngine new];
                self.casinoNode = [AVAudioPlayerNode new];
                [self.casinoEngine attachNode:self.casinoNode];
                [self.casinoEngine connect:self.casinoNode to:self.casinoEngine.mainMixerNode format:file.processingFormat];
                self.casinoEngine.mainMixerNode.outputVolume = .5;
                [self.casinoNode scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
            }
        }
        } @catch (NSException *e) {
        }
    }
}
- (void)viewDidLoad { [super viewDidLoad]; [self setupCasinoAmbience]; self.navigationController.modalInPresentation=YES; /* Pin the slot flow: a swipe down must not dismiss the picker or a game mid-session; the Back button is the way out. */ self.loungeHelper=[[BRSlotChatBar alloc] initWithRoomID:@"brainrot-classic"]; self.loungeHelper.hostViewController=self; [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(profileDidUpdate) name:BRSlotProfileDidUpdateNotification object:nil]; /* One title per page: the SLOT GAMES header below is this screen's only title; no nav-bar duplicate. */ self.view.backgroundColor=[UIColor colorWithRed:.04 green:.02 blue:.09 alpha:1]; CAGradientLayer *bgGradient=[CAGradientLayer layer]; bgGradient.colors=@[(id)[UIColor colorWithRed:.07 green:.03 blue:.16 alpha:1].CGColor,(id)[UIColor colorWithRed:.03 green:.01 blue:.07 alpha:1].CGColor]; [self.view.layer insertSublayer:bgGradient atIndex:0]; self.backgroundGradient=bgGradient; CAGradientLayer *bgGlow=[CAGradientLayer layer]; bgGlow.type=kCAGradientLayerRadial; bgGlow.colors=@[(id)[UIColor colorWithRed:.45 green:.25 blue:.95 alpha:.30].CGColor,(id)[UIColor colorWithRed:.45 green:.25 blue:.95 alpha:0].CGColor]; bgGlow.startPoint=CGPointMake(.5,.5); bgGlow.endPoint=CGPointMake(1,1); [self.view.layer insertSublayer:bgGlow atIndex:1]; self.backgroundGlow=bgGlow; self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:[self navigationButton]]; self.navigationItem.rightBarButtonItems=@[[[UIBarButtonItem alloc] initWithCustomView:(self.profileAvatarButton=[self profileButton])],[[UIBarButtonItem alloc] initWithCustomView:[self winsButton]],[[UIBarButtonItem alloc] initWithCustomView:(self.soundButton=[self soundToggleButton])]]; self.importableGames=BRGameLibrary.shared.allRecords;
    BRSlotPickerHeroView *hero=[[BRSlotPickerHeroView alloc] initWithTitle:NSLocalizedString(@"BRSlot.Picker.Header", nil) tagline:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Tagline", nil, NSBundle.mainBundle, @"SPIN \u2022 EXPLORE \u2022 WIN", nil)]; hero.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:hero];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new]; layout.minimumLineSpacing=13; layout.minimumInteritemSpacing=13; layout.sectionInset=UIEdgeInsetsMake(12,18,24,18); self.collectionView=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout]; self.collectionView.backgroundColor=UIColor.clearColor; self.collectionView.dataSource=self; self.collectionView.delegate=self; self.collectionView.alwaysBounceVertical=YES; self.collectionView.translatesAutoresizingMaskIntoConstraints=NO; [self.collectionView registerClass:BRSlotPickerCard.class forCellWithReuseIdentifier:@"SlotCard"]; [self.view addSubview:self.collectionView];
    [NSLayoutConstraint activateConstraints:@[[hero.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[hero.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[hero.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[hero.heightAnchor constraintEqualToConstant:104],[self.collectionView.topAnchor constraintEqualToAnchor:hero.bottomAnchor constant:10],[self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; self.backgroundGradient.frame=self.view.bounds; CGFloat bgw=CGRectGetWidth(self.view.bounds); self.backgroundGlow.frame=CGRectMake(bgw*-.1,-180,bgw*1.2,420); }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.loungeHelper fetchOwnProfile]; [self refreshProfileAvatarButton]; [self refreshSoundButton]; self.importableGames=BRGameLibrary.shared.allRecords; [self.collectionView reloadData]; if (self.casinoNode && !self.casinoNode.isPlaying && BRSlotSoundEnabled()) { @try { if (!self.casinoEngine.isRunning) [self.casinoEngine startAndReturnError:nil]; [self.casinoNode play]; } @catch (NSException *e) { } } }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self.casinoNode pause]; }
- (UIButton *)navigationButton { UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:NSLocalizedString(@"BRSlot.Picker.Back", nil) forState:UIControlStateNormal]; button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightBlack]; button.tintColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1]; button.backgroundColor=[UIColor colorWithRed:.13 green:.05 blue:.23 alpha:.96]; button.layer.cornerRadius=9; button.layer.borderWidth=1; button.layer.borderColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:.72].CGColor; button.contentEdgeInsets=UIEdgeInsetsMake(7,10,7,10); [button sizeToFit]; button.layer.shadowColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor; button.layer.shadowOpacity=.45; button.layer.shadowRadius=6; button.layer.shadowOffset=CGSizeZero; [button addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside]; return button; }
- (UIButton *)winsButton { UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:NSLocalizedString(@"BRSlot.Lounge.Wins", nil) forState:UIControlStateNormal]; button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightBlack]; button.tintColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1]; button.backgroundColor=[UIColor colorWithRed:.13 green:.05 blue:.23 alpha:.96]; button.layer.cornerRadius=9; button.layer.borderWidth=1; button.layer.borderColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:.72].CGColor; button.contentEdgeInsets=UIEdgeInsetsMake(7,10,7,10); [button sizeToFit]; button.layer.shadowColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor; button.layer.shadowOpacity=.45; button.layer.shadowRadius=6; button.layer.shadowOffset=CGSizeZero; [button addTarget:self action:@selector(showWinnersBoard) forControlEvents:UIControlEventTouchUpInside]; return button; }
- (UIButton *)soundToggleButton { UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem]; button.backgroundColor=[UIColor colorWithRed:.13 green:.05 blue:.23 alpha:.96]; button.layer.cornerRadius=9; button.layer.borderWidth=1; button.layer.borderColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:.72].CGColor; button.tintColor=[UIColor colorWithRed:1 green:.78 blue:.22 alpha:1]; button.contentEdgeInsets=UIEdgeInsetsMake(7,9,7,9); button.layer.shadowColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor; button.layer.shadowOpacity=.45; button.layer.shadowRadius=6; button.layer.shadowOffset=CGSizeZero; [button addTarget:self action:@selector(toggleSlotSound) forControlEvents:UIControlEventTouchUpInside]; [self refreshSoundButton:button]; [button sizeToFit]; return button; }
- (void)refreshSoundButton { [self refreshSoundButton:self.soundButton]; }
- (void)refreshSoundButton:(UIButton *)button { if (!button) return; [button setImage:[UIImage systemImageNamed:BRSlotSoundEnabled() ? @"speaker.fill" : @"speaker.slash.fill"] forState:UIControlStateNormal]; }
- (void)toggleSlotSound { BOOL on = !BRSlotSoundEnabled(); BRSlotSetSoundEnabled(on); [self refreshSoundButton]; if (!on) { [self.casinoNode pause]; } else if (self.casinoNode && !self.casinoNode.isPlaying) { @try { if (!self.casinoEngine.isRunning) [self.casinoEngine startAndReturnError:nil]; [self.casinoNode play]; } @catch (NSException *e) { } } }
- (UIButton *)profileButton { UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem]; [button setImage:[UIImage systemImageNamed:@"person.crop.circle"] forState:UIControlStateNormal]; button.tintColor=[UIColor colorWithRed:1 green:.78 blue:.22 alpha:1]; button.backgroundColor=[UIColor colorWithRed:.13 green:.05 blue:.23 alpha:.96]; button.layer.cornerRadius=9; button.layer.borderWidth=1; button.layer.borderColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:.72].CGColor; button.contentEdgeInsets=UIEdgeInsetsMake(7,9,7,9); button.translatesAutoresizingMaskIntoConstraints=NO; [NSLayoutConstraint activateConstraints:@[[button.widthAnchor constraintEqualToConstant:40],[button.heightAnchor constraintEqualToConstant:40]]]; button.layer.shadowColor=[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor; button.layer.shadowOpacity=.45; button.layer.shadowRadius=6; button.layer.shadowOffset=CGSizeZero; [button addTarget:self action:@selector(showProfileEditor) forControlEvents:UIControlEventTouchUpInside]; return button; }
- (void)showWinnersBoard { [self.loungeHelper showWinnersBoard]; }
- (void)showProfileEditor { [self.loungeHelper showProfileEditor]; }
- (void)profileDidUpdate { [self refreshProfileAvatarButton]; [self.collectionView reloadData]; }
// The avatar photo renders AlwaysOriginal: the profile button is a system
// button with a gold tintColor, and a photo left on Automatic renders as a
// template — a solid gold square. The SF Symbol placeholder stays templated.
- (void)refreshProfileAvatarButton { NSString *url = self.loungeHelper.profileAvatarURL; if (!url.length || !self.profileAvatarButton) return; __weak typeof(self) weakSelf = self; [BRSlotChatBar loadAvatarThumbnailForURL:url points:36 completion:^(UIImage *image) { if (!image) return; __strong typeof(weakSelf) self = weakSelf; if (!self) return; self.profileAvatarButton.contentEdgeInsets = UIEdgeInsetsMake(4,4,4,4); [self.profileAvatarButton setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal]; self.profileAvatarButton.imageView.contentMode = UIViewContentModeScaleAspectFill; self.profileAvatarButton.imageView.layer.cornerRadius = 9; self.profileAvatarButton.imageView.clipsToBounds = YES; }]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)close { if (self.onReturnToBrainRotMenu) self.onReturnToBrainRotMenu(); else [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { return 15+self.importableGames.count; }
- (BRSlotPickerCardKind)kindAtIndex:(NSInteger)index { static const BRSlotPickerCardKind order[15]={BRSlotPickerCardKindPlunder,BRSlotPickerCardKindPlunderVIP,BRSlotPickerCardKindGolden,BRSlotPickerCardKindGoldenVIP,BRSlotPickerCardKindPhoenix,BRSlotPickerCardKindPhoenixVIP,BRSlotPickerCardKindStarlight,BRSlotPickerCardKindStarlightVIP,BRSlotPickerCardKindPenguin,BRSlotPickerCardKindPenguinVIP,BRSlotPickerCardKindClassic,BRSlotPickerCardKindPenny,BRSlotPickerCardKindCreate,BRSlotPickerCardKindCommunity,BRSlotPickerCardKindBlackjack}; return index<15 ? order[index] : BRSlotPickerCardKindSaved; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)path { BRSlotPickerCard *cell=[collectionView dequeueReusableCellWithReuseIdentifier:@"SlotCard" forIndexPath:path]; BRSlotPickerCardKind kind=[self kindAtIndex:path.item]; if (kind==BRSlotPickerCardKindClassic) [cell configureWithTitle:NSLocalizedString(@"BRSlot.Picker.Classic.Title", nil) premise:NSLocalizedString(@"BRSlot.Picker.Classic.Detail", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindPenny) [cell configureWithTitle:NSLocalizedString(@"BRSlot.Picker.Penny.Title", nil) premise:NSLocalizedString(@"BRSlot.Picker.Penny.Detail", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindPlunder) [cell configureWithTitle:NSLocalizedString(@"BRSlot.Picker.Plunder.Title", nil) premise:NSLocalizedString(@"BRSlot.Picker.Plunder.Detail", nil) image:[BRPlunderBayViewController plunderSymbolImage:@"scatter"] kind:kind]; else if (kind==BRSlotPickerCardKindPlunderVIP) { BOOL vipUnlocked = self.loungeHelper.profileVipPoints >= 50000; [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PlunderVIP.Title", nil, NSBundle.mainBundle, @"Plunder Bay VIP", nil) premise:vipUnlocked ? NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PlunderVIP.Detail", nil, NSBundle.mainBundle, @"The bay, first class. Bets up to 500 and richer line pays for Silver and up.", nil) : NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PlunderVIP.LockedDetail", nil, NSBundle.mainBundle, @"Locked — VIP machines open at Silver: 50,000 VIP points.", nil) image:[BRPlunderBayViewController plunderSymbolImage:@"scatter"] kind:kind]; } else if (kind==BRSlotPickerCardKindGolden) [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Golden.Title", nil, NSBundle.mainBundle, @"Golden Mandarin 金帽福运", nil) premise:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Golden.Detail", nil, NSBundle.mainBundle, @"Five reels, nine lines. Golden hats open a card pick and ×2, ×3 or ×5 free spins.", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindGoldenVIP) { BOOL vipUnlocked = self.loungeHelper.profileVipPoints >= 50000; [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.GoldenVIP.Title", nil, NSBundle.mainBundle, @"Golden Mandarin VIP", nil) premise:vipUnlocked ? NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.GoldenVIP.Detail", nil, NSBundle.mainBundle, @"The court, first class. Bets up to 125 a line and richer line pays for Silver and up.", nil) : NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.GoldenVIP.LockedDetail", nil, NSBundle.mainBundle, @"Locked \u2014 VIP machines open at Silver: 50,000 VIP points.", nil) image:nil kind:kind]; } else if (kind==BRSlotPickerCardKindPhoenix) [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Phoenix.Title", nil, NSBundle.mainBundle, @"Phoenix Pavilion 凤凰阁", nil) premise:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Phoenix.Detail", nil, NSBundle.mainBundle, @"Five reels, twenty-five lines. Golden hats open a card pick and ×2, ×3 or ×5 free spins.", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindPhoenixVIP) { BOOL vipUnlocked = self.loungeHelper.profileVipPoints >= 50000; [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PhoenixVIP.Title", nil, NSBundle.mainBundle, @"Phoenix Pavilion VIP", nil) premise:vipUnlocked ? NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PhoenixVIP.Detail", nil, NSBundle.mainBundle, @"The pavilion, first class. Bets up to 50 a line and richer line pays for Silver and up.", nil) : NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PhoenixVIP.LockedDetail", nil, NSBundle.mainBundle, @"Locked \u2014 VIP machines open at Silver: 50,000 VIP points.", nil) image:nil kind:kind]; } else if (kind==BRSlotPickerCardKindStarlight) [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Starlight.Title", nil, NSBundle.mainBundle, @"Starlight Odyssey", nil) premise:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Starlight.Detail", nil, NSBundle.mainBundle, @"Five reels, twenty-five lines. Warp stars open a card pick and ×2, ×3 or ×5 free spins in deep space.", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindStarlightVIP) { BOOL vipUnlocked = self.loungeHelper.profileVipPoints >= 50000; [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.StarlightVIP.Title", nil, NSBundle.mainBundle, @"Starlight Odyssey VIP", nil) premise:vipUnlocked ? NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.StarlightVIP.Detail", nil, NSBundle.mainBundle, @"The odyssey, first class. Bets up to 50 a line and richer line pays for Silver and up.", nil) : NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.StarlightVIP.LockedDetail", nil, NSBundle.mainBundle, @"Locked \u2014 VIP machines open at Silver: 50,000 VIP points.", nil) image:nil kind:kind]; } else if (kind==BRSlotPickerCardKindPenguin) [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Penguin.Title", nil, NSBundle.mainBundle, @"Penguin Parade", nil) premise:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Penguin.Detail", nil, NSBundle.mainBundle, @"Five reels, nine lines. Golden eggs open a penguin egg hatch for ×2, ×3 or ×5 free spins.", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindPenguinVIP) { BOOL vipUnlocked = self.loungeHelper.profileVipPoints >= 50000; [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PenguinVIP.Title", nil, NSBundle.mainBundle, @"Penguin Parade VIP", nil) premise:vipUnlocked ? NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PenguinVIP.Detail", nil, NSBundle.mainBundle, @"The parade, first class. Bets up to 125 a line and richer line pays for Silver and up.", nil) : NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PenguinVIP.LockedDetail", nil, NSBundle.mainBundle, @"Locked \u2014 VIP machines open at Silver: 50,000 VIP points.", nil) image:nil kind:kind]; } else if (kind==BRSlotPickerCardKindBlackjack) [cell configureWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Blackjack.Title", nil, NSBundle.mainBundle, @"Blackjack", nil) premise:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.Blackjack.Detail", nil, NSBundle.mainBundle, @"Live multiplayer tables with an AI dealer and table chat. Blackjack pays 3:2.", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindCreate) [cell configureWithTitle:NSLocalizedString(@"BRSlot.Picker.Create.Title", nil) premise:NSLocalizedString(@"BRSlot.Picker.Create.Detail", nil) image:nil kind:kind]; else if (kind==BRSlotPickerCardKindCommunity) [cell configureWithTitle:NSLocalizedString(@"BRSlot.Picker.Community.Title", nil) premise:NSLocalizedString(@"BRSlot.Picker.Community.Detail", nil) image:nil kind:kind]; else { BRGameRecord *record=self.importableGames[path.item-15]; [cell configureWithTitle:record.themeTitle.length?record.themeTitle:NSLocalizedString(@"BRSlot.Picker.Saved.Title", nil) premise:record.premise.length?record.premise:NSLocalizedString(@"BRSlot.Picker.Saved.Detail", nil) image:record.backgroundImage kind:kind]; } return cell; }
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path { CGFloat width=floor((CGRectGetWidth(collectionView.bounds)-49)/2.0); return CGSizeMake(MAX(142,width),320); }
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)path { BRSlotPickerCardKind kind=[self kindAtIndex:path.item]; if (kind==BRSlotPickerCardKindPenny) { [self.navigationController pushViewController:[BRPennySlotViewController new] animated:YES]; return; } if (kind==BRSlotPickerCardKindPlunderVIP) { if (self.loungeHelper.profileVipPoints >= 50000) { BRPlunderBayViewController *vipMachine = [BRPlunderBayViewController new]; vipMachine.vipMode = YES; [self.navigationController pushViewController:vipMachine animated:YES]; } else { UIAlertController *locked = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PlunderVIP.LockedTitle", nil, NSBundle.mainBundle, @"VIP — Silver and up", nil) message:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PlunderVIP.LockedMessage", nil, NSBundle.mainBundle, @"VIP machines unlock at 50,000 VIP points. You have %@.", nil), @(self.loungeHelper.profileVipPoints)] preferredStyle:UIAlertControllerStyleAlert]; [locked addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:locked animated:YES completion:nil]; } return; } if (kind==BRSlotPickerCardKindPlunder) { [self.navigationController pushViewController:[BRPlunderBayViewController new] animated:YES]; return; } if (kind==BRSlotPickerCardKindGolden) { [self.navigationController pushViewController:[BRGoldenMandarinSlotViewController new] animated:YES]; return; } if (kind==BRSlotPickerCardKindGoldenVIP) { if (self.loungeHelper.profileVipPoints >= 50000) { BRGoldenMandarinSlotViewController *vipMachine = [BRGoldenMandarinSlotViewController new]; vipMachine.vipMode = YES; [self.navigationController pushViewController:vipMachine animated:YES]; } else { UIAlertController *locked = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.GoldenVIP.LockedTitle", nil, NSBundle.mainBundle, @"VIP \u2014 Silver and up", nil) message:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.GoldenVIP.LockedMessage", nil, NSBundle.mainBundle, @"VIP machines unlock at 50,000 VIP points. You have %@.", nil), @(self.loungeHelper.profileVipPoints)] preferredStyle:UIAlertControllerStyleAlert]; [locked addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:locked animated:YES completion:nil]; } return; } if (kind==BRSlotPickerCardKindPhoenix) { [self.navigationController pushViewController:[BRPhoenixPavilionSlotViewController new] animated:YES]; return; } if (kind==BRSlotPickerCardKindPhoenixVIP) { if (self.loungeHelper.profileVipPoints >= 50000) { BRPhoenixPavilionSlotViewController *vipMachine = [BRPhoenixPavilionSlotViewController new]; vipMachine.vipMode = YES; [self.navigationController pushViewController:vipMachine animated:YES]; } else { UIAlertController *locked = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PhoenixVIP.LockedTitle", nil, NSBundle.mainBundle, @"VIP \u2014 Silver and up", nil) message:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PhoenixVIP.LockedMessage", nil, NSBundle.mainBundle, @"VIP machines unlock at 50,000 VIP points. You have %@.", nil), @(self.loungeHelper.profileVipPoints)] preferredStyle:UIAlertControllerStyleAlert]; [locked addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:locked animated:YES completion:nil]; } return; } if (kind==BRSlotPickerCardKindStarlight) { [self.navigationController pushViewController:[BRStarlightOdysseySlotViewController new] animated:YES]; return; } if (kind==BRSlotPickerCardKindStarlightVIP) { if (self.loungeHelper.profileVipPoints >= 50000) { BRStarlightOdysseySlotViewController *vipMachine = [BRStarlightOdysseySlotViewController new]; vipMachine.vipMode = YES; [self.navigationController pushViewController:vipMachine animated:YES]; } else { UIAlertController *locked = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.StarlightVIP.LockedTitle", nil, NSBundle.mainBundle, @"VIP \u2014 Silver and up", nil) message:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.StarlightVIP.LockedMessage", nil, NSBundle.mainBundle, @"VIP machines unlock at 50,000 VIP points. You have %@.", nil), @(self.loungeHelper.profileVipPoints)] preferredStyle:UIAlertControllerStyleAlert]; [locked addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:locked animated:YES completion:nil]; } return; } if (kind==BRSlotPickerCardKindPenguin) { [self.navigationController pushViewController:[BRPenguinParadeSlotViewController new] animated:YES]; return; } if (kind==BRSlotPickerCardKindPenguinVIP) { if (self.loungeHelper.profileVipPoints >= 50000) { BRPenguinParadeSlotViewController *vipMachine = [BRPenguinParadeSlotViewController new]; vipMachine.vipMode = YES; [self.navigationController pushViewController:vipMachine animated:YES]; } else { UIAlertController *locked = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PenguinVIP.LockedTitle", nil, NSBundle.mainBundle, @"VIP \u2014 Silver and up", nil) message:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRSlot.Picker.PenguinVIP.LockedMessage", nil, NSBundle.mainBundle, @"VIP machines unlock at 50,000 VIP points. You have %@.", nil), @(self.loungeHelper.profileVipPoints)] preferredStyle:UIAlertControllerStyleAlert]; [locked addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:locked animated:YES completion:nil]; } return; } if (kind==BRSlotPickerCardKindBlackjack) { [self.navigationController pushViewController:[BRBlackjackLobbyViewController new] animated:YES]; return; } if (kind==BRSlotPickerCardKindCommunity) { BRGamePickerViewController *community=[BRGamePickerViewController new]; community.startsOnCommunityTab=YES; __weak typeof(self) weakSelf=self; community.onSlotThemeSelection=^(BRGameRecord *record) { __strong typeof(weakSelf) self=weakSelf; if (self) [self.navigationController pushViewController:[[BRSlotMachineViewController alloc] initWithBrainRotGameRecord:record] animated:YES]; }; community.onClosedWithoutSelection=^{ __strong typeof(weakSelf) self=weakSelf; if (self) [self close]; }; community.modalPresentationStyle=UIModalPresentationFullScreen; [self presentViewController:community animated:YES completion:nil]; return; } BRSlotMachineViewController *slots=kind==BRSlotPickerCardKindSaved?[[BRSlotMachineViewController alloc] initWithBrainRotGameRecord:self.importableGames[path.item-15]]:[BRSlotMachineViewController new]; if (kind==BRSlotPickerCardKindCreate) slots.title=NSLocalizedString(@"BRSlot.Picker.NewGame", nil); [self.navigationController pushViewController:slots animated:YES]; }
@end
