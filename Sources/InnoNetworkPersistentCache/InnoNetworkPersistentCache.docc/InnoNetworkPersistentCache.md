# ``InnoNetworkPersistentCache``

Persist HTTP response cache entries to disk with conservative privacy defaults.

## Overview

`InnoNetworkPersistentCache` provides ``PersistentResponseCache``, an on-disk
``InnoNetwork/ResponseCache`` implementation for apps that want cached
responses to survive process restarts.

By default the cache rejects responses tied to credential-like request headers,
`Set-Cookie`, and `Cache-Control: private`. It also applies
``PersistentResponseCacheConfiguration/DataProtectionClass/completeUnlessOpen``
file protection on supported Apple platforms.

## Topics

### Cache

- ``PersistentResponseCache``
- ``PersistentResponseCacheConfiguration``
