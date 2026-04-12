#import "EZSystemCell.h"

@implementation EZSystemCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _messageLabel = [[UILabel alloc] init];
    _messageLabel.numberOfLines = 0;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.font = [UIFont systemFontOfSize:12];
    _messageLabel.textColor = [UIColor secondaryLabelColor];
    _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_messageLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_messageLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
        [_messageLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
        [_messageLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_messageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
    ]];

    return self;
}

@end
