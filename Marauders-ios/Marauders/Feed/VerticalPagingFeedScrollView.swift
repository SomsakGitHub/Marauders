//
//  VerticalPagingFeedScrollView.swift
//  Marauders
//

import SwiftUI
import UIKit

/// UIKit vertical paging — player layers live in scroll content so video moves 1:1 with the finger.
struct VerticalPagingFeedScrollView: UIViewRepresentable {
    let pageCount: Int
    @Binding var currentPageIndex: Int
    let engine: FeedPlayerEngine
    var onPageSettled: (Int) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> VerticalFeedPagingView {
        let view = VerticalFeedPagingView()
        view.delegate = context.coordinator
        view.syncPlayer(with: engine)
        view.onTap = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onTap()
        }
        return view
    }

    func updateUIView(_ uiView: VerticalFeedPagingView, context: Context) {
        context.coordinator.parent = self
        uiView.setPageCount(pageCount, scrollToIndex: currentPageIndex)
        uiView.syncPlayer(with: engine)
    }

    final class Coordinator: NSObject, VerticalFeedPagingViewDelegate {
        var parent: VerticalPagingFeedScrollView

        init(parent: VerticalPagingFeedScrollView) {
            self.parent = parent
        }

        func pagingViewDidSettle(on pageIndex: Int) {
            parent.currentPageIndex = pageIndex
            parent.onPageSettled(pageIndex)
        }
    }
}

protocol VerticalFeedPagingViewDelegate: AnyObject {
    func pagingViewDidSettle(on pageIndex: Int)
}

final class VerticalFeedPagingView: UIView {
    weak var delegate: VerticalFeedPagingViewDelegate?

    private let scrollView = UIScrollView()
    private let playerCompositor = FeedPlayerCompositorView()
    private var pageViews: [UIView] = []
    private var pageCount = 0
    private var playbackPageIndex = 0

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        addSubview(scrollView)

        scrollView.addSubview(playerCompositor)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func syncPlayer(with engine: FeedPlayerEngine) {
        playerCompositor.sync(with: engine)
    }

    func setPageCount(_ count: Int, scrollToIndex: Int) {
        let safeCount = max(count, 0)
        guard safeCount != pageCount else {
            scrollToPage(scrollToIndex, animated: false)
            return
        }

        pageCount = safeCount
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews.removeAll()

        for _ in 0..<safeCount {
            let page = UIView()
            page.backgroundColor = .black
            scrollView.addSubview(page)
            pageViews.append(page)
        }

        scrollView.addSubview(playerCompositor)
        playbackPageIndex = min(max(scrollToIndex, 0), max(safeCount - 1, 0))
        setNeedsLayout()
        layoutIfNeeded()
        scrollToPage(playbackPageIndex, animated: false)
        repositionPlayerHost()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let width = bounds.width
        let height = bounds.height
        guard height > 0 else { return }

        scrollView.contentSize = CGSize(width: width, height: height * CGFloat(pageCount))

        for (index, page) in pageViews.enumerated() {
            page.frame = CGRect(x: 0, y: CGFloat(index) * height, width: width, height: height)
        }
        repositionPlayerHost()
    }

    private func repositionPlayerHost() {
        let height = bounds.height
        guard height > 0 else { return }
        let width = bounds.width
        playerCompositor.frame = CGRect(
            x: 0,
            y: CGFloat(playbackPageIndex) * height,
            width: width,
            height: height
        )
        scrollView.bringSubviewToFront(playerCompositor)
    }

    private func scrollToPage(_ index: Int, animated: Bool) {
        let height = bounds.height
        guard height > 0, pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        let offset = CGPoint(x: 0, y: CGFloat(clamped) * height)
        scrollView.setContentOffset(offset, animated: animated)
    }

    private func pageIndex(for scrollView: UIScrollView) -> Int {
        let height = scrollView.bounds.height
        guard height > 0, pageCount > 0 else { return 0 }
        let index = Int(round(scrollView.contentOffset.y / height))
        return min(max(index, 0), pageCount - 1)
    }

    private func settleIfNeeded(_ scrollView: UIScrollView) {
        let index = pageIndex(for: scrollView)
        if playbackPageIndex != index {
            playbackPageIndex = index
            repositionPlayerHost()
        }
        delegate?.pagingViewDidSettle(on: index)
    }

    @objc private func handleTap() {
        onTap?()
    }
}

extension VerticalFeedPagingView: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleIfNeeded(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settleIfNeeded(scrollView)
        }
    }
}
