#!/bin/bash

# Ensure pandoc and wkhtmltopdf are installed
if ! command -v pandoc &> /dev/null
then
    echo "pandoc could not be found, please install it."
    exit
fi

if ! command -v wkhtmltopdf &> /dev/null
then
    echo "wkhtmltopdf could not be found, please install it."
    exit
fi

# Create a markdown file with your CV content
cat << EOF > Brian_Nooning_CV.md
# Brian Nooning
iOS Developer | Security Researcher | Reverse Engineering Specialist
Key Largo, FL | djvs23@gmail.com | GitHub: @Tweaker177 | X: @BrianVS

## Summary
Resourceful and detail-oriented iOS Developer with over a decade of experience in Objective-C, Logos, and Reverse Engineering. Proven track record of developing and maintaining a software suite with an estimated 1 million+ global downloads across major repositories. Specializes in runtime injection, system-level UI customization, and security research on jailbroken environments. Transitioning expertise from low-level Objective-C/C++ to modern Swift/SwiftUI development. Experienced in analyzing closed-source binaries, integrating REST APIs, and maintaining legacy codebases across major iOS architecture shifts (32-bit to 64-bit, Rootful to Rootless).

## Technical Skills
- Languages: Objective-C (Expert), C++ (Proficient), Logos/Theos (Expert), Swift/SwiftUI (Intermediate), Python, Solidity, JavaScript (Node.js).
- iOS Internals: SpringBoard Injection, UIKit, CoreAnimation, AutoLayout, Runtime Swizzling (Cydia Substrate/Substitute).
- Tools & Security: Xcode, IDA Pro, Hopper Disassembler, Theos, Git, RESTful APIs, JSON parsing, Penetration Testing (Research/White Hat).
- Legacy Systems: Pascal, Visual Basic, BASIC (Commodore 64).

## Experience
### Independent iOS Developer & Repository Maintainer | Self-Employed
**(i0s_tweak3r)**
2014 – Present
- **EZCompleteUI Development**: Developed and open-sourced EZCompleteUI on GitHub, featuring intelligent under-the-hood helper models that optimize token use, memory management, and context, significantly enhancing response speed. Engaged the community for contributions and feedback to continuously improve the project.
- Product Lifecycle Management: Developed, deployed, and maintained over 60 unique iOS software packages hosted on BigBoss, Packix, and YouRepo. Managed architecture transitions from iOS 7 through iOS 16+, ensuring compatibility across Rootful and Rootless environments.
- Reverse Engineering & Security Analysis: Utilized IDA Pro and Hopper to analyze compiled Swift and Objective-C binaries. Identified private frameworks within iOS to create hooks for system-wide UI customization.
- High-Impact Projects: LockscreenSuite (comprehensive customization), AutoRotate (SBOrientationLockManager hooks), YourDismissedTY (dismissing persistent UIAlerts).
- Open Source Maintenance: Revived and maintained abandoned community libraries like libimagepicker and BetterSettings. Contributed to Snoverlay.
- API & Backend Integration: Implemented REST API handling for license verification and update checks.

### Freelance Software Developer & Technical Consultant | Various Clients
2010 – 2014
- Provided custom software solutions and debugging services for private clients.
- Specialized in identifying security vulnerabilities in mobile applications for research purposes.

## Education
Bachelor of Science in Computer Science (C++ / OOP Focus)
Interamerican University of Puerto Rico, Recinto San Germá n

## Receipts: Impact & Reach
- Total Ecosystem Reach: Estimated 1,000,000+ installs.
- Official BigBoss Downloads: 206,788+ verified downloads.
- Portfolio Volume: 69+ Active Packages on YouRepo; 60+ Legacy Packages on BigBoss/Packix.
- iDownloadBlog (IDB): Featured 'Stylish', 'ModernBarz', and 'LegiBilly'.
- YouTube: Featured on EverythingApplePro (8M+ Subscribers) and iCrackUriDevice 'Top Tweaks'.
- Ethical Development: Built accessibility and utility tools (NoLockScreenCam).
- Open Source Advocate: Open-sourced AutoRotate for community contribution.
- The Fixer: Known for patching broken projects (BetterSettings) for new iOS versions.
EOF

# Convert the markdown file to PDF using pandoc
pandoc Brian_Nooning_CV.md -o Brian_Nooning_CV.pdf --pdf-engine=wkhtmltopdf

# Clean up the markdown file
rm Brian_Nooning_CV.md

echo "PDF generated successfully as Brian_Nooning_CV.pdf"
