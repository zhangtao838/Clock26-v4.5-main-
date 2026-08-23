#import <UIKit/UIKit.h>

// Forward declarations for Preferences.framework classes.
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end
@interface PSTableCell : UITableViewCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier;
@end
@interface PSControlTableCell : PSTableCell
- (UIControl *)control;
@end
@interface PSSliderTableCell : PSControlTableCell
- (void)setValue:(id)value;
@end

// Two-row slider cell:
//   row 1: [名称]                        [数值]
//   row 2: [=========滑块=========]
//
// Both rows are inset by one CJK character width on left/right (the stock
// slider spans edge-to-edge and looks too wide). The value readout sits on
// the same row as the title, right-aligned — exactly "字体大小右边对齐
// (滑条上方右角)".
//
// Specifier keys:
//   cellClass  = C26SliderCell        (required)
//   c26Title   = 字体大小             (left-hand name)
//   c26Format  = decimal | integer    (decimal = one decimal place, default integer)
@interface C26SliderCell : PSSliderTableCell
@end

@implementation C26SliderCell {
    UILabel *_c26Title;
    UILabel *_c26Value;
    BOOL     _c26Decimal;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSString *fmt = [specifier propertyForKey:@"c26Format"];
        _c26Decimal = [fmt isEqualToString:@"decimal"];

        NSString *title = [specifier propertyForKey:@"c26Title"];
        if (title.length == 0) title = [specifier propertyForKey:@"label"];

        _c26Title = [[UILabel alloc] initWithFrame:CGRectZero];
        _c26Title.font = [UIFont systemFontOfSize:15.0f];
        _c26Title.textColor = [UIColor labelColor];
        _c26Title.text = title;
        [self.contentView addSubview:_c26Title];

        _c26Value = [[UILabel alloc] initWithFrame:CGRectZero];
        _c26Value.font = [UIFont monospacedDigitSystemFontOfSize:14.0f
                                                          weight:UIFontWeightSemibold];
        _c26Value.textColor = [UIColor secondaryLabelColor];
        _c26Value.textAlignment = NSTextAlignmentRight;
        _c26Value.adjustsFontSizeToFitWidth = YES;
        _c26Value.minimumScaleFactor = 0.7f;
        [self.contentView addSubview:_c26Value];

        UISlider *s = [self c26Slider];
        if (s) [s addTarget:self action:@selector(c26Changed:)
                   forControlEvents:UIControlEventValueChanged];
        [self c26Refresh];
    }
    return self;
}

// Two-row cell needs more height than the stock 44pt slider row.
- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, 78.0f);
}

- (UISlider *)c26Slider {
    UIControl *c = [self control];
    if ([c isKindOfClass:[UISlider class]]) return (UISlider *)c;
    return [self c26FindSliderIn:self];
}

- (UISlider *)c26FindSliderIn:(UIView *)root {
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:[UISlider class]]) return (UISlider *)v;
        UISlider *s = [self c26FindSliderIn:v];
        if (s) return s;
    }
    return nil;
}

- (void)c26Refresh {
    UISlider *s = [self c26Slider];
    if (!s) return;
    _c26Value.text = _c26Decimal
        ? [NSString stringWithFormat:@"%.1f", s.value]
        : [NSString stringWithFormat:@"%.0f", s.value];
}

- (void)c26Changed:(UISlider *)s { [self c26Refresh]; }

- (void)setValue:(id)value {
    [super setValue:value];
    [self c26Refresh];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    // One CJK-character inset on each side (~15pt @15pt font) on top of the
    // stock cell padding, so the slider + labels don't run edge-to-edge.
    const CGFloat kInset = 16.0f;   // one character width
    const CGFloat kPadTop = 8.0f;
    const CGFloat kRowGap = 4.0f;

    CGRect cb = self.contentView.bounds;
    CGFloat w = cb.size.width;
    CGFloat innerX = kInset;
    CGFloat innerW = w - kInset * 2.0f;

    // Row 1: title (left) + value (right)
    CGFloat row1Y = kPadTop;
    CGFloat row1H = 22.0f;
    _c26Title.frame = CGRectMake(innerX, row1Y, innerW * 0.6f, row1H);
    _c26Value.frame = CGRectMake(innerX + innerW * 0.6f, row1Y,
                                  innerW * 0.4f, row1H);

    // Row 2: slider fills the full inner width
    UISlider *s = [self c26Slider];
    if (s) {
        CGFloat row2Y = row1Y + row1H + kRowGap;
        CGFloat row2H = 32.0f;
        s.frame = CGRectMake(innerX, row2Y, innerW, row2H);
        s.autoresizingMask = UIViewAutoresizingNone;
        s.translatesAutoresizingMaskIntoConstraints = YES;
    }

    [self.contentView bringSubviewToFront:_c26Title];
    [self.contentView bringSubviewToFront:_c26Value];
    [self c26Refresh];
}

@end
