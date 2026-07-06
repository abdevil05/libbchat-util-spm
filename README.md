# LibBchat-Util Swift Package Manager

This is a repo to expose releases of [LibBchat-Util](https://github.com/peter-pratt/libbchat-util)

so that it can be consumed as a Swift Package.

This is a separate repo because Swift Package Manager does a full clone when retrieving its
dependencies and, with its submodules, `LibBchat-Util` can end up being large enough to cause
issues with CI (and be annoying for contributors).

## Current version

* LibBchat-Util: *1.0.0*
