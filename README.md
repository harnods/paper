# Paper

A minimal markdown writing app for macOS and iOS. Just paper.

## Requirements

- Xcode 16+
- macOS 14+ / iOS 17+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to generate the Xcode project)

## Setup

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open Paper.xcodeproj
```

## Features

- Plain markdown writing on a clean paper surface
- Paper styles: plain, dotted grid, ruled lines
- Stacked paper view for multiple documents
- SwiftData persistence
- Shared codebase for macOS and iOS

## Architecture

- **SwiftUI** multiplatform app
- **SwiftData** for document persistence
- No dependencies, no frameworks — just Apple APIs
