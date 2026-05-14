// MobGpuView.swift — Metal-backed fragment-shader surface.
//
// Hosts an `MTKView` inside a SwiftUI `UIViewRepresentable`. Compiles the
// MSL fragment shader supplied by the BEAM into a render pipeline, binds
// per-frame uniforms into fragment buffer slot 0, and renders a
// full-screen quad at the display's refresh rate.
//
// Scope (v1):
//   - Fragment-shader-only. Built-in vertex shader emits a full-screen
//     NDC quad with a (0..1, 0..1) `uv` in `VertexOut.uv`.
//   - Uniforms map keys become member names in the `Uniforms` struct.
//     Supported types: float (NSNumber), float2/3/4 (NSArray of 2/3/4
//     numbers), uint (NSNumber promoted to integer). The uniform struct
//     layout is a flat sequence of 16-byte-aligned slots — matches MSL's
//     default alignment for vec types.
//   - Shader compile errors surface as a translucent red overlay with the
//     error message, on top of the (black) Metal view.
//
// Not yet:
//   - Textures (camera frame, ML output) as samplers
//   - Vertex shader override / custom mesh
//   - GLSL → MSL transpilation (escape hatch via the BEAM-side
//     %{ios: "..."} map form is the workaround; transpile is a future task)

import Foundation
import Metal
import MetalKit
import SwiftUI

// MARK: - SwiftUI wrapper

struct MobGpuView: UIViewRepresentable {
    let node: MobNode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MobGpuMTKView {
        let view = MobGpuMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false  // continuous mode
        view.delegate = view  // self-delegate; renderer logic lives in MobGpuMTKView
        return view
    }

    func updateUIView(_ view: MobGpuMTKView, context: Context) {
        if let shader = node.gpuShaderMSL {
            view.setShader(shader)
        } else {
            view.setShader(nil)
        }
        view.setUniforms(node.gpuUniforms ?? [])
    }

    final class Coordinator {}
}

// MARK: - MTKView subclass + renderer

/// A self-delegating MTKView that compiles MSL fragment shaders on demand
/// and renders a full-screen quad with caller-supplied uniforms.
final class MobGpuMTKView: MTKView, MTKViewDelegate {
    // Compiled shader pipeline (nil until first valid shader arrives).
    private var pipelineState: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var compileError: String?
    private var currentShaderHash: Int = 0
    private var uniformBuffer: MTLBuffer?
    private var uniformBytes = Data()

    // SwiftUI host for the error overlay. Rendered as a UILabel pinned to
    // the top-left so the user sees compile errors inline.
    private weak var errorLabel: UILabel?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        self.commandQueue = device?.makeCommandQueue()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.commandQueue = self.device?.makeCommandQueue()
    }

    // MARK: shader handoff from SwiftUI

    func setShader(_ source: String?) {
        guard let source = source, !source.isEmpty else {
            if pipelineState != nil { pipelineState = nil; showError(nil) }
            return
        }
        let hash = source.hashValue
        if hash == currentShaderHash, pipelineState != nil { return }
        currentShaderHash = hash
        compileShader(source)
    }

    func setUniforms(_ uniforms: Any) {
        // Uniforms arrive as a top-level NSArray (BEAM-side list) — packed
        // in declaration order so the order survives JSON round-trip and
        // map-iteration surprises. Each element is either:
        //   - NSNumber (float or int → 4-byte slot at natural alignment)
        //   - NSArray of 2 numbers (float2 → 8-byte slot at 8-byte align)
        //   - NSArray of 4 numbers (float4 → 16-byte slot at 16-byte align)
        //
        // The shader then declares its `Uniforms` struct with members in
        // the SAME order:
        //
        //     struct Uniforms {
        //         float2 center;   // matches uniforms[0]
        //         float  zoom;     // matches uniforms[1]
        //         uint   max_iter; // matches uniforms[2]
        //     };
        //
        // (Map form was tempting but Elixir map iteration order is
        // not stable beyond ~32 entries and differs across runtimes —
        // discovered this empirically when the demo rendered black on
        // device because :zoom came first on iOS BEAM.)
        var data = Data()
        if let list = uniforms as? [Any] {
            for value in list {
                appendUniformValue(value, to: &data)
            }
        } else if let dict = uniforms as? [AnyHashable: Any] {
            // Fallback for backward compat — iteration order undefined.
            // The shader-side struct MUST match whatever the runtime decides.
            // Not recommended; use the list form above.
            for (_, value) in dict {
                appendUniformValue(value, to: &data)
            }
        }
        uniformBytes = data
        if data.count > 0 {
            uniformBuffer = device?.makeBuffer(bytes: (data as NSData).bytes, length: data.count, options: [])
        } else {
            uniformBuffer = nil
        }
    }

    private func appendUniformValue(_ value: Any, to data: inout Data) {
        if let n = value as? NSNumber {
            let typeStr = String(cString: n.objCType)
            if typeStr == "q" || typeStr == "l" || typeStr == "i" {
                alignTo(4, in: &data)
                var v: UInt32 = UInt32(truncatingIfNeeded: n.int64Value)
                data.append(Data(bytes: &v, count: 4))
            } else {
                alignTo(4, in: &data)
                var v: Float = n.floatValue
                data.append(Data(bytes: &v, count: 4))
            }
            return
        }
        if let arr = value as? [Any] {
            switch arr.count {
            case 2:
                alignTo(8, in: &data)
                for i in 0..<2 {
                    if let n = arr[i] as? NSNumber {
                        var v: Float = n.floatValue
                        data.append(Data(bytes: &v, count: 4))
                    }
                }
            case 4:
                alignTo(16, in: &data)
                for i in 0..<4 {
                    if let n = arr[i] as? NSNumber {
                        var v: Float = n.floatValue
                        data.append(Data(bytes: &v, count: 4))
                    }
                }
            default:
                // Unsupported arity (3 reserved for future float3,
                // others unhandled). Skip silently — shader-side will
                // read garbage, which is at least localizable in a debug.
                break
            }
        }
    }

    private func alignTo(_ alignment: Int, in data: inout Data) {
        let mod = data.count % alignment
        if mod != 0 { data.append(Data(count: alignment - mod)) }
    }

    // MARK: compile

    private func compileShader(_ source: String) {
        guard let device = device else { return }

        let full = """
        \(vertexSource)
        \(source)
        """

        do {
            let library = try device.makeLibrary(source: full, options: nil)
            guard let vertexFn = library.makeFunction(name: "vertex_main") else {
                showError("internal: vertex_main not found in built-in vertex source")
                return
            }
            // Convention: fragment entry point is called `fragment_main`. If
            // the supplied shader exports a function with a different name,
            // make_function returns nil and we surface that to the user.
            guard let fragmentFn = library.makeFunction(name: "fragment_main") else {
                showError("fragment_main not found — your shader must define `fragment half4 fragment_main(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]])`")
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            showError(nil)
        } catch {
            pipelineState = nil
            showError(String(describing: error))
        }
    }

    private var vertexSource: String {
        // Full-screen quad in clip space + a passthrough uv in (0..1, 0..1).
        // The fragment shader writes `Uniforms` member layout itself; we
        // don't generate the struct here.
        return """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
            // Quad as a triangle strip: BL, BR, TL, TR
            float2 pos[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            float2 uv[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };
            VertexOut out;
            out.position = float4(pos[vid], 0.0, 1.0);
            out.uv = uv[vid];
            return out;
        }
        """
    }

    // MARK: error overlay

    private func showError(_ message: String?) {
        compileError = message
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let message = message {
                if self.errorLabel == nil {
                    let label = UILabel(frame: self.bounds)
                    label.numberOfLines = 0
                    label.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                    label.textColor = .white
                    label.backgroundColor = UIColor.red.withAlphaComponent(0.7)
                    label.lineBreakMode = .byWordWrapping
                    label.textAlignment = .left
                    label.translatesAutoresizingMaskIntoConstraints = false
                    self.addSubview(label)
                    NSLayoutConstraint.activate([
                        label.topAnchor.constraint(equalTo: self.topAnchor),
                        label.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                        label.trailingAnchor.constraint(equalTo: self.trailingAnchor)
                    ])
                    self.errorLabel = label
                }
                self.errorLabel?.text = "shader error:\n\(message)"
                self.errorLabel?.isHidden = false
            } else {
                self.errorLabel?.isHidden = true
            }
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = pipelineState,
              let cmdBuf = commandQueue?.makeCommandBuffer(),
              let renderPass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: renderPass)
        else {
            // Either no shader compiled yet or pipeline failed — let the
            // overlay (if any) speak for itself; nothing to draw.
            currentDrawable?.present()
            return
        }

        encoder.setRenderPipelineState(pipeline)
        if let buf = uniformBuffer {
            encoder.setFragmentBuffer(buf, offset: 0, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
