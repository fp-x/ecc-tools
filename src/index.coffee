DefaultAlgoritm = 'aes'
Algorithms =
  aes: 'aes-256-cbc'
  triple: 'triplesec'
  triplesec: 'triplesec'
  'aes-256-cbc': 'aes-256-cbc'

promise = Promise ? require('es6-promise').Promise

crypto = require 'crypto'
secp256k1 = require 'secp256k1'
triplesec = require 'triplesec'

bs58check = require 'bs58check'
bs58 = require 'bs58'

stringify = require 'json-stable-stringify'

assert = (condition, message) ->
  if !condition then throw new Error(message || "Assertion failed")

equalConstTime = (b1, b2) ->
  return false if (b1.length != b2.length)
  res = 0
  res |= b1[i] ^ b2[i] for i in [0...b1.length]
  res == 0;

pad32 = (msg) ->
  if (msg.length < 32)
    buf = Buffer.alloc(32)
    buf.fill(0)
    msg.copy(buf, 32 - msg.length)
    return buf
  else return msg

ecctoolkit =
  stringify: stringify
  bs58check: bs58check
  secp256k1: secp256k1

  rmd160: (msg) -> crypto.createHash("rmd160").update(msg).digest()
  sha256: (msg) -> crypto.createHash("sha256").update(msg).digest()
  sha512: (msg) -> crypto.createHash("sha512").update(msg).digest()
  ripemd160: (msg) -> crypto.createHash("ripemd160").update(msg).digest()

  sha256ripemd160: (msg) -> ecctoolkit.ripemd160(ecctoolkit.sha256(msg))
  sha256sha256: (msg) -> ecctoolkit.sha256(ecctoolkit.sha256(msg))

  hash: (msg, alg='sha256') ->
    algs =
      rmd160: @rmd160
      sha256: @sha256
      sha512: @sha512
    if msg? then algs[alg](msg)
    else algs

  hmacSha256: (key, msg) -> crypto.createHmac("sha256", key).update(msg).digest()

  checksum: (msg, alg) -> @hash(stringify(msg), alg)

  xor: (a, b, len=Math.max(a.length, b.length)) ->
    tmp = Buffer.alloc(len)
    tmp[i] = a[i] ^ b[i] for i in [0...len]
    tmp

  zip: (a, b) -> Buffer.concat([a[i],b[i]].filter((e)->e?)) for i in [0...(Math.max(a.length, b.length))]

  chunk: (buf, size) -> buf.slice((size*i), (size*i)+size) for i in [0...(buf.length/size)]

  combine: (key, version) -> Buffer.concat @zip(@chunk(version,1),@chunk(key,Math.floor(key.length/version.length)))

  isHex: (str) -> str.match(/^([0-9a-fA-F]{2})+$/)?

  isBase58: (str) -> str.match(/^([1-9A-HJ-NP-Za-km-z])+$/)?

  decode58check: (str, mask=(Buffer.alloc(0))) ->
    msg = bs58.decode(str)
    payload = msg.slice(0, -4)
    payload if msg.slice(-4).equals(@xor(@sha256sha256(payload), mask, 4))

  decode: (msg, mask) ->
    if (msg instanceof Buffer) then msg
    else if (typeof msg is not 'string') then throw new Error('Must be a buffer or a string')
    else if @isBase58(msg) && buf = @decode58check(msg, mask) then buf
    else if @isHex(msg) then Buffer.from(msg, 'hex')
    else throw new Error('Unable to decode')

  encode: (msg, mask=(Buffer.alloc(0))) ->
    checksum = @xor(@sha256sha256(msg), mask, 4)
    bs58.encode Buffer.concat([msg, checksum], msg.length+4)

  address: (key, version, mask) -> @encode(@combine(@sha256ripemd160(key), version), mask)

  privateKey: ->  crypto.randomBytes(32)
  publicKey: (privateKey, compressed=false) -> secp256k1.publicKeyCreate(privateKey, compressed)

  publicKeyConvert: (publicKey, compressed=false) -> secp256k1.publicKeyConvert(publicKey, compressed)

  derive: (privateKey, publicKey) -> secp256k1.ecdhUnsafe(publicKey, privateKey).slice(1,33)

  sign: (msg, privateKey) ->
    msg = msg.toBuffer?() ? msg
    privateKey = privateKey.toBuffer?() ? privateKey
    assert(msg.length > 0, "Message should not be empty")
    assert(msg.length <= 32, "Message is too long")
    sig = secp256k1.sign(pad32(msg), privateKey).signature
    secp256k1.signatureExport(sig)

  verify: (msg, publicKey, sig) ->
    msg = Buffer.from(msg.toBuffer?() ? msg)
    sig = Buffer.from(sig.toBuffer?() ? sig)
    publicKey = Buffer.from(publicKey.toBuffer?() ? publicKey)
    assert(msg.length > 0, "Message should not be empty")
    assert(msg.length <= 32, "Message is too long")
    sig = secp256k1.signatureImport(sig)
    secp256k1.verify(pad32(msg), sig, publicKey)

  encrypt: (plaintext, publicKey, algorithm=DefaultAlgoritm) ->
    promise.resolve(plaintext).then (plaintext) =>
      algorithm = Algorithms[algorithm] ? algorithm

      privateKey = crypto.randomBytes(32)
      ephemeralKey = @publicKey(privateKey, true)
      hash = @sha512(@derive(privateKey, publicKey))
      iv = crypto.randomBytes(16)
      encryptionKey = hash.slice(0, 32)
      macKey = hash.slice(32)

      @cipher(plaintext, encryptionKey, iv, algorithm).then (ciphertext) =>
        dataToMac = Buffer.concat([iv, ephemeralKey, ciphertext])
        mac = @hmacSha256(macKey, dataToMac)

        iv: iv
        mac: mac
        ciphertext: ciphertext
        ephemeralKey: ephemeralKey

  decrypt: (cipher, privateKey, algorithm=DefaultAlgoritm) ->
    promise.resolve(cipher).then (cipher) =>
      algorithm = Algorithms[algorithm] ? algorithm

      ciphertext = cipher.ciphertext.toBuffer?() ? cipher.ciphertext
      iv = cipher.iv.toBuffer?() ? cipher.iv
      mac = cipher.mac.toBuffer?() ? cipher.mac
      ephemPublicKey = cipher.ephemeralKey.toBuffer?() ? cipher.ephemeralKey

      hash = @sha512(@derive(privateKey, ephemPublicKey))
      encryptionKey = hash.slice(0, 32)
      macKey = hash.slice(32)
      dataToMac = Buffer.concat([
        iv,
        ephemPublicKey,
        ciphertext
      ])
      realMac = @hmacSha256(macKey, dataToMac)
      assert(equalConstTime(mac, realMac), 'Bad MAC')
      @decipher(ciphertext, encryptionKey, iv, algorithm)

  cipher: (plaintext, key, iv, algorithm=DefaultAlgoritm) ->
    promise.resolve(plaintext).then (plaintext) ->
      algorithm = Algorithms[iv] ? Algorithms[algorithm] ? algorithm
      plaintext = stringify(plaintext)

      switch algorithm
        when 'triplesec'
          new promise (resolve, reject) ->
            triplesec.encrypt { data: Buffer.from(plaintext), key: key }, (err, ciphertext) ->
              if err? then reject(new Error(err))
              else resolve(ciphertext)
        else
          cipher = crypto.createCipheriv(algorithm, key, iv)
          firstChunk = cipher.update(plaintext)
          secondChunk = cipher.final()
          Buffer.concat([firstChunk, secondChunk])
    .then (ciphertext) -> Buffer.from(ciphertext)

  decipher: (ciphertext, key, iv, algorithm=DefaultAlgoritm) ->
    promise.resolve(ciphertext).then (ciphertext) ->
      algorithm = Algorithms[iv] ? Algorithms[algorithm]

      switch algorithm
        when 'triplesec'
          new promise (resolve, reject) ->
            triplesec.decrypt { data: ciphertext, key: key }, (err, ciphertext) ->
              if err? then reject(new Error(err))
              else resolve(ciphertext)
        else
          cipher = crypto.createDecipheriv(algorithm, key, iv)
          firstChunk = cipher.update(ciphertext)
          secondChunk = cipher.final()
          Buffer.concat([firstChunk, secondChunk])

    .then (plaintext) -> JSON.parse(plaintext)

  reverse: (buf) ->
    if (typeof buf is 'string') then buf = Buffer.from(buf, 'hex')
    tmp = Buffer.alloc(buf.length)
    for b, i in buf
      tmp[buf.length-1-i] = b
    tmp


module.exports = ecctoolkit
