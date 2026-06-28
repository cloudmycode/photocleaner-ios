import SwiftUI
import UIKit

/// 与系统相册相同：UIScrollView 双指捏合缩放/平移，双击以触点为中心放大，再双击还原。
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    @Binding var isZoomed: Bool
    var resetTrigger: Int = 0
    var maxZoomScale: CGFloat = 4
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed, content: content())
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = maxZoomScale
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isScrollEnabled = false

        let hostView = context.coordinator.hostingController.view!
        hostView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hostView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.lastResetTrigger = resetTrigger
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content()
        guard context.coordinator.lastResetTrigger != resetTrigger else { return }
        context.coordinator.lastResetTrigger = resetTrigger
        context.coordinator.resetZoom(on: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isZoomed: Bool
        let hostingController: UIHostingController<Content>
        weak var scrollView: UIScrollView?
        var lastResetTrigger = 0

        init(isZoomed: Binding<Bool>, content: Content) {
            _isZoomed = isZoomed
            hostingController = UIHostingController(rootView: content)
            hostingController.view.backgroundColor = .clear
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
            let zoomed = scrollView.zoomScale > 1.01
            scrollView.isScrollEnabled = zoomed
            isZoomed = zoomed
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            let zoomed = scale > 1.01
            scrollView.isScrollEnabled = zoomed
            isZoomed = zoomed
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let view = hostingController.view else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let point = gesture.location(in: view)
            let side = min(scrollView.bounds.width, scrollView.bounds.height) / 2
            let origin = CGPoint(x: point.x - side / 2, y: point.y - side / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: CGSize(width: side, height: side)), animated: true)
        }

        func resetZoom(on scrollView: UIScrollView) {
            scrollView.setZoomScale(1, animated: false)
            scrollView.isScrollEnabled = false
            isZoomed = false
        }

        private func centerContent(in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let insetX = max((bounds.width - content.width) * 0.5, 0)
            let insetY = max((bounds.height - content.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }
    }
}
