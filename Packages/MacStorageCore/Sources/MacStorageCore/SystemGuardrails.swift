import Foundation

/// Classification of a protection rule.
public enum GuardrailLevel: String, Codable, Sendable, CaseIterable {
    /// Always enforced — cannot be disabled (OS integrity).
    case mandatory
    /// On by default; user may turn off after confirmation.
    case recommended
    /// Off by default; user may enable for extra caution.
    case optional
}

public struct GuardrailRule: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var prefixes: [String]
    public var level: GuardrailLevel
    /// When true, matches if path contains the fragment (for Time Machine mounts, etc.)
    public var containsFragments: [String]

    public init(
        id: String,
        title: String,
        detail: String,
        prefixes: [String] = [],
        level: GuardrailLevel,
        containsFragments: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.prefixes = prefixes
        self.level = level
        self.containsFragments = containsFragments
    }
}

/// Interactive OS / system-file guardrails for scan + cleanup.
public final class SystemGuardrails: @unchecked Sendable {
    public static let shared = SystemGuardrails()

    private let defaults = UserDefaults.standard
    private let disabledKey = "mss.guardrails.disabledRuleIDs"

    public let catalog: [GuardrailRule] = [
        GuardrailRule(
            id: "os-system",
            title: "macOS System Volume",
            detail: "SIP-protected OS files under /System. Never scanned or deleted.",
            prefixes: ["/System"],
            level: .mandatory
        ),
        GuardrailRule(
            id: "os-binaries",
            title: "System Binaries",
            detail: "Core command-line tools and daemons required to boot and run macOS.",
            prefixes: ["/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/usr/standalone"],
            level: .mandatory
        ),
        GuardrailRule(
            id: "os-private",
            title: "Private System Data",
            detail: "Kernel, dyld shared cache, VM swap, and other private OS state.",
            prefixes: [
                "/private/var/vm",
                "/private/var/db/dyld",
                "/private/var/db/KernelExtensionManagement",
                "/private/var/db/InstallerSandboxData",
                "/private/var/folders",  // system temp; user caches live elsewhere
                "/private/tmp",
                "/private/var/tmp",
            ],
            level: .mandatory
        ),
        GuardrailRule(
            id: "os-root-special",
            title: "Root Special Directories",
            detail: "Device nodes, network mounts, and process filesystem.",
            prefixes: ["/dev", "/proc", "/Network", "/cores"],
            level: .mandatory
        ),
        GuardrailRule(
            id: "os-apfs-meta",
            title: "APFS & Spotlight Metadata",
            detail: "Filesystem journals, Spotlight indexes, and document versions.",
            prefixes: [
                "/.Spotlight-V100",
                "/.DocumentRevisions-V100",
                "/.fseventsd",
                "/.TemporaryItems",
                "/.vol",
                "/.file",
            ],
            level: .mandatory
        ),
        GuardrailRule(
            id: "os-preboot",
            title: "Preboot & Recovery",
            detail: "Boot and recovery volumes used by macOS updates.",
            prefixes: ["/System/Volumes/Preboot", "/System/Volumes/Update", "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware", "/System/Volumes/VM"],
            level: .mandatory
        ),
        GuardrailRule(
            id: "time-machine",
            title: "Time Machine & Snapshots",
            detail: "Backup mounts and local snapshots. Safe to skip for free-space analysis.",
            prefixes: ["/Volumes/com.apple.TimeMachine", "/.MobileBackups"],
            level: .recommended,
            containsFragments: ["/.MobileBackups", "/com.apple.TimeMachine", "/Backups.backupdb"]
        ),
        GuardrailRule(
            id: "system-library",
            title: "System Library",
            detail: "Global /Library frameworks and support files. Recommended to skip; does not include ~/Library.",
            prefixes: ["/Library"],
            level: .recommended
        ),
        GuardrailRule(
            id: "system-applications",
            title: "Built-in System Applications",
            detail: "Apple apps shipped under /System/Applications.",
            prefixes: ["/System/Applications"],
            level: .mandatory
        ),
        GuardrailRule(
            id: "usr-local",
            title: "Protect /usr/local",
            detail: "Optional: also skip Homebrew and other tools under /usr/local.",
            prefixes: ["/usr/local"],
            level: .optional
        ),
        GuardrailRule(
            id: "opt",
            title: "Protect /opt",
            detail: "Optional: skip third-party packages under /opt (e.g. some SDKs).",
            prefixes: ["/opt"],
            level: .optional
        ),
    ]

    private init() {}

    /// Rule IDs the user has turned off (only recommended/optional may be stored).
    public var disabledRuleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: disabledKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    public func isEnabled(_ rule: GuardrailRule) -> Bool {
        if rule.level == .mandatory { return true }
        return !disabledRuleIDs.contains(rule.id)
    }

    public func setEnabled(_ rule: GuardrailRule, enabled: Bool) {
        guard rule.level != .mandatory else { return }
        var set = disabledRuleIDs
        if enabled {
            set.remove(rule.id)
        } else {
            set.insert(rule.id)
        }
        disabledRuleIDs = set
    }

    public func activeRules() -> [GuardrailRule] {
        catalog.filter { isEnabled($0) }
    }

    /// Prefix list passed to the scanner worker.
    public func excludePrefixes() -> [String] {
        var prefixes: [String] = []
        for rule in activeRules() {
            prefixes.append(contentsOf: rule.prefixes)
        }
        // Always protect volume root itself as a trash target is handled elsewhere
        return Array(Set(prefixes)).sorted()
    }

    public func containsFragments() -> [String] {
        activeRules().flatMap(\.containsFragments)
    }

    /// Whether a path is blocked by an active guardrail.
    public func isProtected(_ path: String) -> Bool {
        evaluation(for: path).isProtected
    }

    public struct Evaluation: Sendable, Equatable {
        public var isProtected: Bool
        public var matchedRuleIDs: [String]
        public var matchedTitles: [String]
        public var isMandatory: Bool

        public init(isProtected: Bool, matchedRuleIDs: [String], matchedTitles: [String], isMandatory: Bool) {
            self.isProtected = isProtected
            self.matchedRuleIDs = matchedRuleIDs
            self.matchedTitles = matchedTitles
            self.isMandatory = isMandatory
        }
    }

    public func evaluation(for path: String) -> Evaluation {
        let standardized = (path as NSString).standardizingPath
        var ids: [String] = []
        var titles: [String] = []
        var mandatory = false

        // Exact critical roots
        let criticalExact = ["/", "/Users", "/Applications", "/Volumes"]
        if criticalExact.contains(standardized) {
            return Evaluation(
                isProtected: true,
                matchedRuleIDs: ["critical-root"],
                matchedTitles: ["Critical system root"],
                isMandatory: true
            )
        }
        if standardized == NSHomeDirectory() {
            return Evaluation(
                isProtected: true,
                matchedRuleIDs: ["home-root"],
                matchedTitles: ["Home folder root"],
                isMandatory: true
            )
        }

        for rule in catalog {
            guard isEnabled(rule) else { continue }
            var hit = false
            for prefix in rule.prefixes {
                if standardized == prefix || standardized.hasPrefix(prefix + "/") {
                    hit = true
                    break
                }
                // Case-insensitive for safety
                let s = standardized.lowercased()
                let p = prefix.lowercased()
                if s == p || s.hasPrefix(p + "/") {
                    hit = true
                    break
                }
            }
            if !hit {
                for frag in rule.containsFragments {
                    if standardized.contains(frag) {
                        hit = true
                        break
                    }
                }
            }
            // /usr/local is under /usr — if only os-binaries active, /usr/local was listed separately
            // Ensure /usr alone doesn't use incomplete match: prefixes already specific

            // Special: protect all of /usr except when only non-matching
            if !hit && rule.id == "os-binaries" {
                let s = standardized
                if s == "/usr" || (s.hasPrefix("/usr/") && !s.hasPrefix("/usr/local")) {
                    hit = true
                }
            }

            if hit {
                ids.append(rule.id)
                titles.append(rule.title)
                if rule.level == .mandatory { mandatory = true }
            }
        }

        return Evaluation(
            isProtected: !ids.isEmpty,
            matchedRuleIDs: ids,
            matchedTitles: titles,
            isMandatory: mandatory
        )
    }

    /// Filter scan roots so we never start a walk on a protected prefix.
    public func filterRoots(_ roots: [String]) -> [String] {
        roots.filter { root in
            let eval = evaluation(for: root)
            // Allow home and /Applications and volumes; block pure OS roots
            if root == NSHomeDirectory() { return true }
            if root == "/Applications" || root.hasSuffix("/Applications") { return true }
            if root.hasPrefix("/Volumes/") { return true }
            if root == "/Users" { return true }
            if root == "/usr/local" || root == "/opt" {
                return !isProtected(root)
            }
            if eval.isProtected && eval.isMandatory { return false }
            if root == "/System" || root.hasPrefix("/System/") { return false }
            if root == "/Library",
               let libRule = catalog.first(where: { $0.id == "system-library" }),
               isEnabled(libRule) {
                return false
            }
            return true
        }
    }
}

