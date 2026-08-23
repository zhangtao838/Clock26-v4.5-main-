#import <UIKit/UIKit.h>

// LiquidGlassView — 液态玻璃效果视图
// 用 Metal 渲染：背景模糊 + 边缘折射 + RGB色散 + 高光
// 通过 maskView 获取形状（通常是时间数字 UILabel）
@interface LiquidGlassView : UIView

@property (nonatomic, assign) CGFloat blurRadius;       // 模糊半径 0-50，默认 20
@property (nonatomic, assign) CGFloat glassThickness;    // 玻璃厚度 0-30，默认 12
@property (nonatomic, assign) CGFloat refractionScale;   // 折射强度 0-3，默认 1.0
@property (nonatomic, assign) CGFloat specularOpacity;   // 高光不透明度 0-1，默认 0.6
@property (nonatomic, assign) CGFloat dispersion;        // 色散强度 0-1，默认 0.5
@property (nonatomic, weak)   UIView *maskView;          // 形状来源视图（时间数字 label）

// 标记需要重新截取背景/mask并渲染
- (void)setNeedsUpdate;

@end
