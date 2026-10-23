import SwiftUI
import UIKit

struct VerticalPagingFeedScrollView: UIViewRepresentable {
    let streamURLs: [URL]
    @Binding var currentPageIndex: Int
    let engine: FeedPlayerEngine
    var onPageSettled: (Int) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> VerticalFeedPagingView {
        let view = VerticalFeedPagingView()
        view.delegate = context.coordinator
        view.onTap = { [weak coordinator = context.coordinator] in coordinator?.parent.onTap() }
        return view
    }
    func updateUIView(_ view: VerticalFeedPagingView, context: Context) {
        context.coordinator.parent = self
        view.setVideos(streamURLs, scrollToIndex: currentPageIndex)
        view.syncPresentations(engine.presentations)
    }
    final class Coordinator: NSObject, VerticalFeedPagingViewDelegate {
        var parent: VerticalPagingFeedScrollView
        init(parent: VerticalPagingFeedScrollView) { self.parent = parent }
        func pagingViewDidSettle(on index: Int) {
            parent.currentPageIndex = index
            parent.onPageSettled(index)
        }
    }
}

@MainActor
protocol VerticalFeedPagingViewDelegate: AnyObject { func pagingViewDidSettle(on pageIndex: Int) }

/// Each surface stays at its video's content coordinate throughout a drag and snap.
final class VerticalFeedPagingView: UIView {
    weak var delegate: VerticalFeedPagingViewDelegate?
    var onTap: (() -> Void)?
    private let scrollView = UIScrollView()
    private var streamURLs: [URL] = []
    private var presentations: [FeedPlayerPresentation] = []
    private var hosts: [Int: FeedPlayerLayerHostView] = [:]
    private var settledIndex = 0
    private var previousSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scrollView.backgroundColor = .black
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        addSubview(scrollView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVideos(_ urls: [URL], scrollToIndex: Int) {
        let changed = streamURLs != urls
        streamURLs = urls
        let target = min(max(scrollToIndex, 0), max(urls.count - 1, 0))
        if changed { setNeedsLayout(); layoutIfNeeded() }
        if !scrollView.isDragging && !scrollView.isDecelerating, target != settledIndex || changed {
            settledIndex = target
            scrollToSettledPage()
        }
        positionSurfaces()
    }
    func syncPresentations(_ newPresentations: [FeedPlayerPresentation]) {
        presentations = newPresentations
        for presentation in newPresentations {
            let host: FeedPlayerLayerHostView
            if let existing = hosts[presentation.id] { host = existing }
            else {
                host = FeedPlayerLayerHostView()
                hosts[presentation.id] = host
                scrollView.addSubview(host)
            }
            host.attach(layer: presentation.layer)
        }
        positionSurfaces()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = bounds.size != previousSize
        previousSize = bounds.size
        scrollView.frame = bounds
        scrollView.contentSize = CGSize(width: bounds.width, height: bounds.height * CGFloat(streamURLs.count))
        if resized && !scrollView.isDragging && !scrollView.isDecelerating { scrollToSettledPage() }
        positionSurfaces()
    }
    private func positionSurfaces() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for presentation in presentations {
            guard let host = hosts[presentation.id] else { continue }
            guard let url = presentation.url, let index = streamURLs.firstIndex(of: url) else {
                host.isHidden = true
                continue
            }
            host.isHidden = false
            host.frame = CGRect(x: 0, y: CGFloat(index) * bounds.height, width: bounds.width, height: bounds.height)
        }
    }
    private func scrollToSettledPage() {
        guard bounds.height > 0 else { return }
        let offset = CGPoint(x: 0, y: CGFloat(settledIndex) * bounds.height)
        if scrollView.contentOffset != offset { scrollView.setContentOffset(offset, animated: false) }
    }
    private func settle() {
        guard bounds.height > 0, !streamURLs.isEmpty else { return }
        settledIndex = min(max(Int(round(scrollView.contentOffset.y / bounds.height)), 0), streamURLs.count - 1)
        delegate?.pagingViewDidSettle(on: settledIndex)
        // No surface is moved here. Paging only selects which audio/video should play.
    }
    @objc private func handleTap() { onTap?() }
}

extension VerticalFeedPagingView: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }
}
