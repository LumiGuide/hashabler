1.0
    - Added a `mix64` method, in use in, `Word/Int64` `ByteString` types and `P.ByteArray`
    - `Hash` renamed `HashState` and roll clarified in docs
    - `instance Hashable` of `Float` and `Double` now use `mix32` and `mix64` respectively.
    - Implemented 64-bit and 128-bit siphash
    - instances up to 15-tuples. Now web scale!

0.1.0.2
    (initial release)

