import SwiftUI
import UIKit

// ── Zoomable image (`zoomable: true` on :image) ──────────────────────────────
//
// Pinch to zoom (1x ... max_zoom), double-tap to zoom in to double_tap_zoom
// around the tapped point (again to return to 1x), one-finger pan while
// zoomed. All of it is native; nothing round-trips to the BEAM, because a
// gesture that waits on Elixir for every frame cannot track a finger.
//
// A UIScrollView rather than SwiftUI's MagnifyGesture: the scroll view already
// does zoom-about-the-pinch-centre, clamped panning, zoom bounce and
// deceleration, and its pan recognizer can be switched off at 1x. That switch
// is the contract with a parent scroll or pager: at 1x a one-finger drag must
// reach the parent untouched, so the pan recognizer is enabled only while the
// picture is zoomed in.
//
// The frame is the zoom viewport. It fills the space it is offered, and an
// axis with no bound (the main axis of a vertical scroll) takes its length
// from the picture's aspect ratio. The picture is aspect-fitted inside the
// frame and centred while it is smaller than the frame on either axis.
struct MobZoomableImage: View {
    let node: MobNode

    // The loaded picture's size, tagged with the src it belongs to, so the
    // unbounded-axis sizing in sizeThatFits can follow the aspect ratio. It is
    // state because the picture arrives after the first layout (a download, or
    // a decode deferred off the update pass), and SwiftUI only re-measures a
    // representable whose inputs changed.
    @State private var loaded: MobZoomableLoaded?

    var body: some View {
        let src = node.src
        let maxZoom = max(1, node.maxZoom)
        MobZoomableImageView(
            src: src,
            maxZoom: maxZoom,
            doubleTapZoom: min(max(1, node.doubleTapZoom), maxZoom),
            placeholder: node.placeholderColor ?? UIColor.systemGray5,
            imageSize: loaded?.src == src ? loaded?.size : nil,
            onLoad: { loaded = $0 }
        )
        .frame(
            width: node.fixedWidth > 0 ? node.fixedWidth : nil,
            height: node.fixedHeight > 0 ? node.fixedHeight : nil
        )
        .clipShape(RoundedRectangle(cornerRadius: node.cornerRadius))
    }
}

struct MobZoomableLoaded: Equatable {
    let src: String
    let size: CGSize
}

private struct MobZoomableImageView: UIViewRepresentable {
    let src: String?
    let maxZoom: CGFloat
    let doubleTapZoom: CGFloat
    let placeholder: UIColor
    let imageSize: CGSize?
    let onLoad: (MobZoomableLoaded) -> Void

    func makeUIView(context: Context) -> MobZoomScrollView {
        MobZoomScrollView(frame: .zero)
    }

    func updateUIView(_ view: MobZoomScrollView, context: Context) {
        view.maximumZoomScale = maxZoom
        if view.zoomScale > maxZoom { view.setZoomScale(maxZoom, animated: false) }
        view.doubleTapZoom = doubleTapZoom
        view.placeholder = placeholder
        // Deferred: a local file loads synchronously inside setSource, which
        // runs during this view update, and SwiftUI forbids state writes there.
        view.onLoad = { loaded in DispatchQueue.main.async { onLoad(loaded) } }
        view.setSource(src)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MobZoomScrollView,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        // Square until the picture is known, like the placeholder it shows.
        let aspect: CGFloat
        if let size = imageSize, size.width > 0, size.height > 0 {
            aspect = size.width / size.height
        } else {
            aspect = 1
        }
        switch (width, height) {
        case let (width?, height?): return CGSize(width: width, height: height)
        case let (width?, nil): return CGSize(width: width, height: width / aspect)
        case let (nil, height?): return CGSize(width: height * aspect, height: height)
        case (nil, nil): return imageSize
        }
    }
}

final class MobZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var src: String?
    private var task: URLSessionDataTask?
    // The bounds size the content was last fitted to. layoutSubviews runs on
    // every scroll and zoom step; only a real size change refits.
    private var fittedForSize: CGSize = .zero

    var doubleTapZoom: CGFloat = 2.5
    var onLoad: ((MobZoomableLoaded) -> Void)?
    var placeholder: UIColor = .systemGray5 {
        didSet { if imageView.image == nil { backgroundColor = placeholder } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        // Panning stops at the picture's edge; only zoom rubber-bands.
        bounces = false
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        clipsToBounds = true
        backgroundColor = placeholder
        panGestureRecognizer.isEnabled = false
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("MobZoomScrollView is created in code only")
    }

    deinit { task?.cancel() }

    func setSource(_ newSrc: String?) {
        guard newSrc != src else { return }
        src = newSrc
        task?.cancel()
        task = nil
        show(nil)
        guard let newSrc else { return }

        if newSrc.hasPrefix("http://") || newSrc.hasPrefix("https://") {
            guard let url = URL(string: newSrc) else { return }
            // URLSession.shared, so the response goes through the same shared
            // URLCache a non-zoomable image's AsyncImage reads from.
            let request = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                // Decode here, off the main thread, rather than at first draw.
                let image = data.flatMap(UIImage.init(data:)).map { $0.preparingForDisplay() ?? $0 }
                DispatchQueue.main.async {
                    guard let self, self.src == newSrc, let image else { return }
                    self.show(image)
                }
            }
            task = request
            request.resume()
        } else {
            show(MobImageCache.shared.image(atPath: newSrc))
        }
    }

    private func show(_ image: UIImage?) {
        imageView.image = image
        backgroundColor = image == nil ? placeholder : .clear
        fitContent()
        if let image, let src { onLoad?(MobZoomableLoaded(src: src, size: image.size)) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedForSize { fitContent() }
    }

    /// Back to 1x with the picture aspect-fitted and centred in the frame.
    private func fitContent() {
        // Zoom first: contentSize and the image view's frame are both in
        // zoomed units, so resizing them at another scale fits the wrong size.
        setZoomScale(minimumZoomScale, animated: false)
        fittedForSize = bounds.size
        let fitted = fittedImageSize()
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerContent()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        updatePanEnabled()
    }

    private func fittedImageSize() -> CGSize {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// Insets that centre the picture on any axis where it is smaller than the
    /// frame. The scroll view clamps panning to content plus insets, so on an
    /// axis where the zoomed picture is larger than the frame the inset is 0
    /// and its edges cannot be dragged inside the frame's.
    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func updatePanEnabled() {
        panGestureRecognizer.isEnabled = zoomScale - minimumZoomScale > 0.001
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updatePanEnabled()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if zoomScale - minimumZoomScale > 0.001 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let target = min(doubleTapZoom, maximumZoomScale)
        guard target > minimumZoomScale else { return }
        // In the image view's own (unzoomed) coordinates, which is what
        // zoom(to:) takes: a rect 1/target of the frame, centred on the tap.
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height),
             animated: true)
    }
}
