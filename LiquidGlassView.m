#import "LiquidGlassView.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

// =============================================================================
// LiquidGlassView — 液态玻璃效果
//
// 渲染管线：
//   1. 截取 superview 背景 → 纹理
//   2. MPSImageGaussianBlur 模糊背景
//   3. 截取 maskView（时间数字）的 alpha → mask 纹理
//   4. Metal fragment shader：边缘折射 + RGB色散 + 高光，用 mask 裁剪
//
// 省电策略：只在 setNeedsUpdate / layoutSubviews / 参数变化时渲染，
// 不做持续动画。锁屏静态场景下零 CPU/GPU 占用。
// =============================================================================

#pragma mark - Metal shader 源码（运行时编译）
static NSString *const kLiquidGlassShader = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct VertexOut {\n"
"    float4 position [[position]];\n"
"    float2 uv;\n"
"};\n"
"\n"
"vertex VertexOut vertexShader(uint vid [[vertex_id]]) {\n"
"    float2 pos[6] = {\n"
"        float2(-1,-1), float2(1,-1), float2(-1,1),\n"
"        float2(-1,1),  float2(1,-1), float2(1,1)\n"
"    };\n"
"    float2 uv[6] = {\n"
"        float2(0,1), float2(1,1), float2(0,0),\n"
"        float2(0,0), float2(1,1), float2(1,0)\n"
"    };\n"
"    VertexOut out;\n"
"    out.position = float4(pos[vid], 0, 1);\n"
"    out.uv = uv[vid];\n"
"    return out;\n"
"}\n"
"\n"
"struct Uniforms {\n"
"    float2 resolution;\n"
"    float  glassThickness;\n"
"    float  refractionScale;\n"
"    float  specularOpacity;\n"
"    float  dispersion;\n"
"};\n"
"\n"
"fragment float4 fragmentShader(\n"
"    VertexOut in [[stage_in]],\n"
"    texture2d<float> bgTex   [[texture(0)]],\n"
"    texture2d<float> maskTex [[texture(1)]],\n"
"    constant Uniforms& u     [[buffer(0)]]\n"
") {\n"
"    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
"    float2 uv = in.uv;\n"
"\n"
"    // Mask：只在数字形状内渲染\n"
"    float maskAlpha = maskTex.sample(s, uv).a;\n"
"    if (maskAlpha < 0.01) discard_fragment();\n"
"\n"
"    // 边缘检测：从 mask alpha 梯度计算法线\n"
"    float2 texel = 1.0 / max(u.resolution, float2(1.0));\n"
"    float aL = maskTex.sample(s, uv - float2(texel.x, 0)).a;\n"
"    float aR = maskTex.sample(s, uv + float2(texel.x, 0)).a;\n"
"    float aT = maskTex.sample(s, uv - float2(0, texel.y)).a;\n"
"    float aB = maskTex.sample(s, uv + float2(0, texel.y)).a;\n"
"    float2 normal = float2(aL - aR, aT - aB);\n"
"    float edgeStrength = length(normal);\n"
"    if (edgeStrength > 0.001) normal /= edgeStrength;\n"
"\n"
"    // 折射：沿法线方向偏移采样背景\n"
"    float refractAmount = edgeStrength * u.refractionScale * u.glassThickness * 0.008;\n"
"    float2 sampleUV = uv + normal * refractAmount;\n"
"\n"
"    // 色散：RGB 通道轻微分离（棱镜效应）\n"
"    float disp = u.dispersion * edgeStrength * 0.006;\n"
"    float r = bgTex.sample(s, sampleUV + float2(disp, 0)).r;\n"
"    float g = bgTex.sample(s, sampleUV).g;\n"
"    float b = bgTex.sample(s, sampleUV - float2(disp, 0)).b;\n"
"    float3 bgColor = float3(r, g, b);\n"
"\n"
"    // 高光：左上方光源的镜面反射\n"
"    float2 lightDir = normalize(float2(-0.5, -0.8));\n"
"    float spec = pow(max(0.0, dot(normal, lightDir)), 6.0)\n"
"               * u.specularOpacity * edgeStrength * 1.5;\n"
"    bgColor += float3(spec);\n"
"\n"
"    // 玻璃深度：轻微变暗\n"
"    bgColor *= 0.93;\n"
"\n"
"    return float4(bgColor, maskAlpha);\n"
"}\n";

#pragma mark - 私有属性
@interface LiquidGlassView ()
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;

@property (nonatomic, strong) id<MTLTexture> bgTexture;       // 原始背景
@property (nonatomic, strong) id<MTLTexture> blurredTexture;  // 模糊后背景
@property (nonatomic, strong) id<MTLTexture> maskTexture;     // 形状 mask

@property (nonatomic, assign) BOOL metalReady;
@property (nonatomic, assign) BOOL needsRender;
@end

@implementation LiquidGlassView

#pragma mark - 初始化
+ (Class)layerClass { return [CAMetalLayer class]; }

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder:coder]) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    // 默认参数
    _blurRadius = 20.0f;
    _glassThickness = 12.0f;
    _refractionScale = 1.0f;
    _specularOpacity = 0.6f;
    _dispersion = 0.5f;

    self.opaque = NO;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;

    _metalLayer = (CAMetalLayer *)self.layer;
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) { self.hidden = YES; return; }

    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = NO;
    _metalLayer.opaque = NO;

    _commandQueue = [_device newCommandQueue];

    [self buildPipeline];
}

- (void)buildPipeline {
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kLiquidGlassShader
                                                 options:nil
                                                   error:&err];
    if (!lib) { NSLog(@"[LiquidGlass] shader compile failed: %@", err); return; }

    id<MTLFunction> vert = [lib newFunctionWithName:@"vertexShader"];
    id<MTLFunction] frag = [lib newFunctionWithName:@"fragmentShader"];
    if (!vert || !frag) return;

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vert;
    desc.fragmentFunction = frag;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_pipeline) { NSLog(@"[LiquidGlass] pipeline failed: %@", err); return; }

    _uniformBuffer = [_device newBufferWithLength:sizeof(float) * 8
                                           options:MTLResourceStorageModeShared];
    _metalReady = YES;
}

#pragma mark - 布局
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_metalReady) return;
    CGFloat scale = [UIScreen mainScreen].nativeScale;
    _metalLayer.drawableSize = CGSizeMake(self.bounds.size.width * scale,
                                           self.bounds.size.height * scale);
    [self setNeedsUpdate];
}

#pragma mark - 属性 setter（触发重渲染）
- (void)setBlurRadius:(CGFloat)v { _blurRadius = MAX(0, MIN(50, v)); [self setNeedsUpdate]; }
- (void)setGlassThickness:(CGFloat)v { _glassThickness = MAX(0, MIN(30, v)); [self setNeedsUpdate]; }
- (void)setRefractionScale:(CGFloat)v { _refractionScale = MAX(0, MIN(3, v)); [self setNeedsUpdate]; }
- (void)setSpecularOpacity:(CGFloat)v { _specularOpacity = MAX(0, MIN(1, v)); [self setNeedsUpdate]; }
- (void)setDispersion:(CGFloat)v { _dispersion = MAX(0, MIN(1, v)); [self setNeedsUpdate]; }
- (void)setMaskView:(UIView *)v { _maskView = v; [self setNeedsUpdate]; }

- (void)setNeedsUpdate {
    _needsRender = YES;
    [self renderIfNeeded];
}

#pragma mark - 截取背景
- (void)captureBackground {
    if (self.bounds.size.width < 1 || self.bounds.size.height < 1) return;
    UIView *superview = self.superview;
    if (!superview) return;

    CGRect captureRect = [self convertRect:self.bounds toView:superview];
    CGFloat scale = [UIScreen mainScreen].nativeScale;
    CGSize texSize = CGSizeMake(self.bounds.size.width * scale,
                                 self.bounds.size.height * scale);
    if (texSize.width < 1 || texSize.height < 1) return;

    // 隐藏自己，避免递归截图
    BOOL wasHidden = self.hidden;
    self.hidden = YES;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:texSize format:fmt];

    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextTranslateCTM(ctx.CGContext, -captureRect.origin.x * scale,
                              -captureRect.origin.y * scale);
        [superview drawViewHierarchyInRect:superview.bounds afterScreenUpdates:NO];
    }];

    self.hidden = wasHidden;

    if (!img) return;
    _bgTexture = [self textureFromImage:img size:texSize];
}

#pragma mark - 截取 mask
- (void)captureMask {
    if (!_maskView || self.bounds.size.width < 1) return;

    CGFloat scale = [UIScreen mainScreen].nativeScale;
    CGSize texSize = CGSizeMake(self.bounds.size.width * scale,
                                 self.bounds.size.height * scale);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:texSize format:fmt];

    CGRect maskFrame = [_maskView convertRect:_maskView.bounds toView:self];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextTranslateCTM(ctx.CGContext, maskFrame.origin.x * scale,
                              maskFrame.origin.y * scale);
        [_maskView drawViewHierarchyInRect:_maskView.bounds afterScreenUpdates:NO];
    }];

    if (!img) return;
    _maskTexture = [self textureFromImage:img size:texSize];
}

#pragma mark - UIImage → MTLTexture
- (id<MTLTexture>)textureFromImage:(UIImage *)image size:(CGSize)size {
    CGImageRef cgImg = image.CGImage;
    if (!cgImg) return nil;

    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:size.width height:size.height
                                  mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> tex = [_device newTextureWithDescriptor:desc];

    size_t w = CGImageGetWidth(cgImg);
    size_t h = CGImageGetHeight(cgImg);
    size_t bytesPerRow = w * 4;
    void *data = calloc(bytesPerRow * h, 1);
    if (!data) return nil;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(data, w, h, 8, bytesPerRow, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(data); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImg);
    CGContextRelease(ctx);

    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
           mipmapLevel:0 withBytes:data bytesPerRow:bytesPerRow];
    free(data);
    return tex;
}

#pragma mark - 模糊
- (void)blurBackground {
    if (!_bgTexture || _blurRadius < 0.5) { _blurredTexture = _bgTexture; return; }

    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:_bgTexture.pixelFormat
                                     width:_bgTexture.width height:_bgTexture.height
                                  mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _blurredTexture = [_device newTextureWithDescriptor:desc];

    id<MTLCommandBuffer> buf = [_commandQueue commandBuffer];
    MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc]
        initWithDevice:_device sigma:_blurRadius];
    [blur encodeToCommandBuffer:buf
                    sourceTexture:_bgTexture
               destinationTexture:_blurredTexture];
    [buf commit];
    [buf waitUntilCompleted];
}

#pragma mark - 渲染
- (void)renderIfNeeded {
    if (!_metalReady || !_needsRender) return;
    if (self.bounds.size.width < 1 || self.bounds.size.height < 1) return;

    _needsRender = NO;

    [self captureBackground];
    [self captureMask];
    [self blurBackground];

    if (!_blurredTexture || !_maskTexture) return;

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) return;

    // 更新 uniform
    float *u = (float *)_uniformBuffer.contents;
    u[0] = _maskTexture.width;
    u[1] = _maskTexture.height;
    u[2] = _glassThickness;
    u[3] = _refractionScale;
    u[4] = _specularOpacity;
    u[5] = _dispersion;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

    id<MTLCommandBuffer> buf = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [buf renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_pipeline];
    [enc setFragmentTexture:_blurredTexture atIndex:0];
    [enc setFragmentTexture:_maskTexture atIndex:1];
    [enc setFragmentBuffer:_uniformBuffer offset:0 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    [buf presentDrawable:drawable];
    [buf commit];
}

@end
