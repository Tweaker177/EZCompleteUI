//
//  BRGameView.h
//  BrainRotGame
//
//  A lightweight view that draws the grid and player.
//  It uses simple colored rectangles for tiles.
//

#import <UIKit/UIKit.h>
@class BRGameModel;

NS_ASSUME_NONNULL_BEGIN

@interface BRGameView : UIView

@property (nonatomic, strong) BRGameModel *model;

@end

NS_ASSUME_NONNULL_END