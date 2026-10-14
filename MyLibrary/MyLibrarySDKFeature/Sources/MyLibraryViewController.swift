import UIKit
import MyLibrarySDKCore

final class MyLibraryViewController: UIViewController {
    private let data: MyLibraryFlowData
    private let onClose: ((String?) -> Void)?

    init(data: MyLibraryFlowData, onClose: ((String?) -> Void)?) {
        self.data = data
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let host = MyLibrarySDKCore.configuredHostAppName ?? "—"
        let env = MyLibrarySDKCore.configuredEnvironment?.rawValue ?? "—"

        let titleLabel = UILabel()
        titleLabel.text = "MyLibrarySDKCore"
        titleLabel.font = .boldSystemFont(ofSize: 22)
        titleLabel.textAlignment = .center

        let body = UILabel()
        body.numberOfLines = 0
        body.textAlignment = .center
        body.font = .systemFont(ofSize: 15)
        body.text = """
        Host: \(host) (\(env))

        accountNo: \(data.accountNo)
        appCode: \(data.appCode)
        productCode: \(data.productCode)
        """

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close (completed)", for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, body, closeButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [onClose] in
            onClose?("completed")
        }
    }
}
