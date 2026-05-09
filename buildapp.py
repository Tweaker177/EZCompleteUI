import re
import sys
from pathlib import Path

FILE = "ViewController.m"

def patch_file(path):
    content = Path(path).read_text()

    # --- 1. FIX TEXTVIEW TRAILING (avoid conflict with send button) ---
    content = re.sub(
        r'\[self\.promptInput\.trailingAnchor constraintEqualToAnchor:self\.inputContainer\.trailingAnchor constant:-10\]',
        '[self.promptInput.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8]',
        content
    )

    # --- 2. ADD SEND BUTTON INTO INPUT CONTAINER ---
    send_button_block = r"""
#pragma mark - Send Button Setup (Patched)

- (void)setupSendButton {

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;

    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];

    self.sendButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.55 blue:1.0 alpha:1.0];
    self.sendButton.layer.cornerRadius = 10.0;

    [self.inputContainer addSubview:self.sendButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-10],
        [self.sendButton.topAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:8],
        [self.sendButton.bottomAnchor constraintEqualToAnchor:self.inputContainer.bottomAnchor constant:-8],
        [self.sendButton.widthAnchor constraintEqualToConstant:60],
    ]];
}
"""

    if "setupSendButton" not in content:
        content += "\n\n" + send_button_block

    # --- 3. CALL setupSendButton IN viewDidLoad ---
    content = re.sub(
        r'(\[self setupInputUI\];)',
        r'\1\n    [self setupSendButton];',
        content
    )

    # --- 4. REMOVE BAD BOTTOM ANCHORS (tableView tied to screen bottom) ---
    content = re.sub(
        r'\[self\.(tableView|collectionView).*?bottomAnchor constraintEqualToAnchor:self\.view\.(safeAreaLayoutGuide\.)?bottomAnchor.*?\];',
        '// removed bad bottom constraint',
        content
    )

    # --- 5. ADD CORRECT BOTTOM ANCHOR TO INPUT CONTAINER ---
    table_fix = r"""
#pragma mark - TableView Bottom Fix (Patched)

- (void)fixTableViewLayout {

    if (self.tableView) {
        [NSLayoutConstraint activateConstraints:@[
            [self.tableView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:-8]
        ]];
    }
}
"""
    if "fixTableViewLayout" not in content:
        content += "\n\n" + table_fix

    # --- 6. CALL FIX METHOD ---
    content = re.sub(
        r'(\[self setupSendButton\];)',
        r'\1\n    [self fixTableViewLayout];',
        content
    )

    Path(path).write_text(content)
    print("Patched v2 successfully. Your layout should now behave like it has adult supervision.")

if __name__ == "__main__":
    file_path = sys.argv[1] if len(sys.argv) > 1 else FILE

    if not Path(file_path).exists():
        print(f"File not found: {file_path}")
        sys.exit(1)

    patch_file(file_path)
