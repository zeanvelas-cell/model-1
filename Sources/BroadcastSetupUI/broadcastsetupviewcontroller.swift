import UIKit
import ReplayKit

public final class BroadcastSetupViewController: UIViewController {
    private let keyField = UITextField()
    private let toggleKeyVisibilityBtn = UIButton(type: .system)
    private let ingestField = UITextField()
    private let formatControl = UISegmentedControl(items: ["16:9 Landscape", "9:16 Shorts"])
    private let gameVolumeLabel = UILabel()
    private let gameVolumeSlider = UISlider()
    private let micVolumeLabel = UILabel()
    private let micVolumeSlider = UISlider()
    private var didAutoComplete = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 0.96)

        let titleLabel = UILabel()
        titleLabel.text = "PulseLite Game Broadcast Setup"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Used when your sideloader stripped App Groups. Paste your Stream Key and set initial audio levels below."
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center

        keyField.placeholder = "Paste Stream Key (xxxx-xxxx-xxxx-xxxx)"
        keyField.borderStyle = .roundedRect
        keyField.backgroundColor = UIColor(white: 0.14, alpha: 1.0)
        keyField.textColor = .white
        keyField.autocapitalizationType = .none
        keyField.autocorrectionType = .no
        keyField.isSecureTextEntry = true

        toggleKeyVisibilityBtn.setImage(UIImage(systemName: "eye.fill"), for: .normal)
        toggleKeyVisibilityBtn.tintColor = UIColor(white: 0.75, alpha: 1.0)
        toggleKeyVisibilityBtn.frame = CGRect(x: 0, y: 0, width: 38, height: 32)
        toggleKeyVisibilityBtn.addTarget(self, action: #selector(toggleKeyVisibilityTapped), for: .touchUpInside)
        keyField.rightView = toggleKeyVisibilityBtn
        keyField.rightViewMode = .always

        if let savedKey = AppGroupBridge.activeAccount()?.primaryStreamKey, !savedKey.isEmpty {
            keyField.text = savedKey
        }
        // The key is typed or pasted by the user. We never read the clipboard automatically,
        // and we never persist a key typed here so "Flush All Keys" in the main app stays authoritative.

        let currentSettings = AppGroupBridge.loadSettings()
        ingestField.placeholder = "rtmps://a.rtmps.youtube.com:443/live2"
        ingestField.text = currentSettings.ingestServerURL
        ingestField.borderStyle = .roundedRect
        ingestField.backgroundColor = UIColor(white: 0.14, alpha: 1.0)
        ingestField.textColor = .white
        ingestField.autocapitalizationType = .none
        ingestField.autocorrectionType = .no

        formatControl.selectedSegmentIndex = (currentSettings.aspectMode == .landscape16x9) ? 0 : 1
        formatControl.selectedSegmentTintColor = .systemGreen

        gameVolumeSlider.minimumValue = 0.0
        gameVolumeSlider.maximumValue = 1.0
        gameVolumeSlider.value = currentSettings.gameVolume
        gameVolumeSlider.minimumTrackTintColor = .systemGreen
        gameVolumeSlider.addTarget(self, action: #selector(volumeSliderChanged), for: .valueChanged)

        gameVolumeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        gameVolumeLabel.textColor = UIColor(white: 0.85, alpha: 1.0)

        micVolumeSlider.minimumValue = 0.0
        micVolumeSlider.maximumValue = 1.0
        micVolumeSlider.value = currentSettings.micVolume
        micVolumeSlider.minimumTrackTintColor = .systemCyan
        micVolumeSlider.addTarget(self, action: #selector(volumeSliderChanged), for: .valueChanged)

        micVolumeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        micVolumeLabel.textColor = UIColor(white: 0.85, alpha: 1.0)

        updateVolumeLabels()

        let startBtn = UIButton(type: .system)
        startBtn.setTitle("Start Fullscreen Game Broadcast", for: .normal)
        startBtn.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        startBtn.backgroundColor = .systemRed
        startBtn.setTitleColor(.white, for: .normal)
        startBtn.layer.cornerRadius = 12
        startBtn.heightAnchor.constraint(equalToConstant: 46).isActive = true
        startBtn.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("Cancel", for: .normal)
        cancelBtn.setTitleColor(.systemGray, for: .normal)
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            subtitleLabel,
            formatControl,
            keyField,
            ingestField,
            gameVolumeLabel,
            gameVolumeSlider,
            micVolumeLabel,
            micVolumeSlider,
            startBtn,
            cancelBtn
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAutoComplete else { return }
        // Fast-path: If App Groups work and an active key is already saved, complete immediately without making the user tap through the setup sheet!
        if AppGroupBridge.groupAvailable,
           let acct = AppGroupBridge.activeAccount(),
           !acct.primaryStreamKey.isEmpty {
            didAutoComplete = true
            let currentSettings = AppGroupBridge.loadSettings()
            let broadcastURL = URL(string: currentSettings.ingestServerURL) ?? URL(string: "https://youtube.com")!
            let setupInfo: [String: NSCoding & NSObjectProtocol] = [
                "streamKey": acct.primaryStreamKey as NSString,
                "ingestURL": currentSettings.ingestServerURL as NSString,
                "aspectMode": currentSettings.aspectMode.rawValue as NSString,
                "gameVolume": NSNumber(value: currentSettings.gameVolume),
                "micVolume": NSNumber(value: currentSettings.micVolume)
            ]
            extensionContext?.completeRequest(withBroadcast: broadcastURL, setupInfo: setupInfo)
        }
    }

    @objc private func toggleKeyVisibilityTapped() {
        keyField.isSecureTextEntry.toggle()
        let iconName = keyField.isSecureTextEntry ? "eye.fill" : "eye.slash.fill"
        toggleKeyVisibilityBtn.setImage(UIImage(systemName: iconName), for: .normal)
    }

    @objc private func volumeSliderChanged() {
        updateVolumeLabels()
    }

    private func updateVolumeLabels() {
        let gamePct = Int(round(gameVolumeSlider.value * 100))
        let micPct = Int(round(micVolumeSlider.value * 100))
        gameVolumeLabel.text = "Game Volume: \(gamePct)% (0–100%, lowers only)"
        micVolumeLabel.text = "Mic Volume: \(micPct)% (0–100%, lowers only)"
    }

    @objc private func startTapped() {
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ingest = (ingestField.text ?? "rtmps://a.rtmps.youtube.com:443/live2").trimmingCharacters(in: .whitespacesAndNewlines)
        let aspect: StreamAspectMode = (formatControl.selectedSegmentIndex == 0) ? .landscape16x9 : .verticalShorts9x16

        guard !key.isEmpty else {
            keyField.layer.borderColor = UIColor.systemRed.cgColor
            keyField.layer.borderWidth = 1.5
            return
        }

        let broadcastURL = URL(string: ingest) ?? URL(string: "https://youtube.com")!
        let setupInfo: [String: NSCoding & NSObjectProtocol] = [
            "streamKey": key as NSString,
            "ingestURL": ingest as NSString,
            "aspectMode": aspect.rawValue as NSString,
            "gameVolume": NSNumber(value: min(max(gameVolumeSlider.value, 0.0), 1.0)),
            "micVolume": NSNumber(value: min(max(micVolumeSlider.value, 0.0), 1.0))
        ]
        extensionContext?.completeRequest(withBroadcast: broadcastURL, setupInfo: setupInfo)
    }

    @objc private func cancelTapped() {
        let err = NSError(domain: "PulseLiteSetup", code: -2, userInfo: [NSLocalizedDescriptionKey: "User cancelled setup"])
        extensionContext?.cancelRequest(withError: err)
    }
}