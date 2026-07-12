import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_certificate.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_crypto.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_secure_channel.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';

/// Asymmetric OPN loopback for Basic256Sha256.
///
/// The production [OpcSecureChannel] plays the SERVER: it verifies+decrypts a
/// client OPN and signs+encrypts the OPN response. The test provides a small,
/// INDEPENDENT client-side mirror ([_asymSignEncrypt] / [_asymDecryptVerify])
/// written from the Rust `secure_channel.rs` reference — signing with the
/// client key and encrypting to the server cert. If the padding/signed-range/
/// block-chunking match, the round-trip recovers the exact plaintext.
void main() {
  // RSA-2048 keygen is expensive; fixed Fortuna seeds keep the run
  // reproducible and let both keypairs be generated once.
  final serverKp = generateRsa2048(fortunaRandom(List<int>.filled(32, 7)));
  final clientKp = generateRsa2048(fortunaRandom(List<int>.filled(32, 11)));

  final serverCertDer = buildSelfSignedCertificate(
    keyPair: serverKp,
    applicationUri: 'urn:server',
    commonName: 'S',
    notBefore: DateTime.utc(2020),
    notAfter: DateTime.utc(2040),
  );
  final clientCertDer = buildSelfSignedCertificate(
    keyPair: clientKp,
    applicationUri: 'urn:client',
    commonName: 'C',
    notBefore: DateTime.utc(2020),
    notAfter: DateTime.utc(2040),
  );

  final clientNonce = Uint8List.fromList(
      List<int>.generate(kSecureChannelNonceLength, (i) => i + 1));
  final serverNonce = Uint8List.fromList(
      List<int>.generate(kSecureChannelNonceLength, (i) => 200 - i));

  Uint8List seqHeader(int seq, int req) {
    final b = ByteData(8)
      ..setUint32(0, seq, Endian.little)
      ..setUint32(4, req, Endian.little);
    return b.buffer.asUint8List();
  }

  test('asymmetric OPN loopback: client OPN verifies & decrypts; response '
      'round-trips', () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );

    // --- Client -> Server OPN ---
    final requestBody = Uint8List.fromList(
        List<int>.generate(137, (i) => (i * 3 + 5) & 0xff));
    final clientSeqBody =
        Uint8List.fromList(<int>[...seqHeader(1, 1), ...requestBody]);

    final clientFrame = _asymSignEncrypt(
      signKey: clientKp.privateKey,
      encKey: serverKp.publicKey,
      senderCertDer: clientCertDer,
      receiverThumbprint: sha1(serverCertDer),
      secureChannelId: 0,
      sequenceNumber: 1,
      requestId: 1,
      plainSeqBody: clientSeqBody,
    );

    final hdr = parseChunkHeader(clientFrame);
    expect(hdr.messageType, 'OPN');
    expect(hdr.securityPolicyUri, kSecurityPolicyBasic256Sha256Uri);
    final rawHeader =
        Uint8List.sublistView(clientFrame, 0, hdr.securityHeaderEnd);
    final rawAfter =
        Uint8List.sublistView(clientFrame, hdr.securityHeaderEnd, hdr.size);

    final recovered = channel.openFromClient(
      policyUri: hdr.securityPolicyUri!,
      senderCertificate: Uint8List.fromList(hdr.senderCertificate!),
      rawHeader: rawHeader,
      rawAfterSecurityHeader: rawAfter,
      serverNonce: serverNonce,
      clientNonce: clientNonce,
    );
    expect(recovered, equals(clientSeqBody));
    expect(channel.mode, OpcSecurityMode.signAndEncrypt);
    expect(channel.clientCertificate, isNotNull);
    // Keys derived for Task 5.
    expect(channel.clientKeys!.signingKey.length, 32);
    expect(channel.clientKeys!.encryptingKey.length, 32);
    expect(channel.clientKeys!.iv.length, 16);

    // --- Server -> Client OPN response ---
    final respBody = Uint8List.fromList(
        List<int>.generate(60, (i) => (i * 7 + 1) & 0xff));
    final respSeqBody =
        Uint8List.fromList(<int>[...seqHeader(1, 1), ...respBody]);

    final respFrame = channel.buildSecuredOpnResponse(
      secureChannelId: 42,
      sequenceNumber: 1,
      requestId: 1,
      plaintextSequenceAndBody: respSeqBody,
    );

    final respHdr = parseChunkHeader(respFrame);
    expect(respHdr.secureChannelId, 42);
    expect(respFrame.length, respHdr.size); // header size == final frame size

    final recoveredResp = _asymDecryptVerify(
      decKey: clientKp.privateKey,
      verifyKey: serverKp.publicKey,
      frame: respFrame,
    );
    expect(recoveredResp, equals(respSeqBody));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('None policy passes through unchanged both ways', () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );
    final remainder = Uint8List.fromList(<int>[...seqHeader(3, 9), 1, 2, 3, 4]);
    final out = channel.openFromClient(
      policyUri: kSecurityPolicyNoneUri,
      senderCertificate: null,
      rawHeader: Uint8List(0),
      rawAfterSecurityHeader: remainder,
      serverNonce: serverNonce,
      clientNonce: clientNonce,
    );
    expect(out, equals(remainder));
    expect(channel.mode, OpcSecurityMode.none);

    final resp = channel.buildSecuredOpnResponse(
      secureChannelId: 5,
      sequenceNumber: 3,
      requestId: 9,
      plaintextSequenceAndBody: remainder,
    );
    final chunk = parseChunk(resp);
    expect(chunk.messageType, 'OPN');
    expect(chunk.securityPolicyUri, kSecurityPolicyNoneUri);
    expect(chunk.body, equals(Uint8List.fromList(<int>[1, 2, 3, 4])));
  });

  test('malformed encrypted OPN throws OpcSecurityException, never uncaught',
      () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );
    // 256 bytes of garbage that will not OAEP-decrypt cleanly.
    final garbage = Uint8List.fromList(List<int>.filled(256, 0xAB));
    expect(
      () => channel.openFromClient(
        policyUri: kSecurityPolicyBasic256Sha256Uri,
        senderCertificate: clientCertDer,
        rawHeader: Uint8List(12),
        rawAfterSecurityHeader: garbage,
        serverNonce: serverNonce,
        clientNonce: clientNonce,
      ),
      throwsA(isA<OpcSecurityException>()),
    );
  });
}

/// Independent client-side mirror of the server's asymmetric sign+encrypt.
Uint8List _asymSignEncrypt({
  required RSAPrivateKey signKey,
  required RSAPublicKey encKey,
  required Uint8List senderCertDer,
  required Uint8List receiverThumbprint,
  required int secureChannelId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List plainSeqBody,
}) {
  const plainBlock = 214;
  const cipherBlock = 256;
  const sigSize = 256;

  final body = Uint8List.sublistView(plainSeqBody, 8);
  final plainFrame = buildOpnChunk(
    secureChannelId: secureChannelId,
    securityPolicyUri: kSecurityPolicyBasic256Sha256Uri,
    senderCertificate: senderCertDer,
    receiverCertificateThumbprint: receiverThumbprint,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
  final headerSize = plainFrame.length - plainSeqBody.length;

  final encryptSize = 8 + body.length + sigSize + 1;
  final rem = encryptSize % plainBlock;
  final pInner = rem == 0 ? 0 : plainBlock - rem;
  final padTotal = 1 + pInner;
  final pad = Uint8List(padTotal)..fillRange(0, padTotal, pInner & 0xff);

  final encPlainLen = plainSeqBody.length + padTotal + sigSize;
  final tmp = Uint8List(headerSize + encPlainLen);
  tmp.setRange(0, plainFrame.length, plainFrame);
  tmp.setRange(plainFrame.length, plainFrame.length + padTotal, pad);

  final cipherTextSize = (encPlainLen ~/ plainBlock) * cipherBlock;
  ByteData.sublistView(tmp, 4, 8)
      .setUint32(0, headerSize + cipherTextSize, Endian.little);

  final signedEnd = tmp.length - sigSize;
  var sig = rsaPkcs1Sha256Sign(signKey, Uint8List.sublistView(tmp, 0, signedEnd));
  if (sig.length < sigSize) {
    final padded = Uint8List(sigSize);
    padded.setRange(sigSize - sig.length, sigSize, sig);
    sig = padded;
  }
  tmp.setRange(signedEnd, tmp.length, sig);

  final out = BytesBuilder(copy: true);
  out.add(Uint8List.sublistView(tmp, 0, headerSize));
  for (var i = headerSize; i < tmp.length; i += plainBlock) {
    out.add(rsaOaepSha1Encrypt(encKey, Uint8List.sublistView(tmp, i, i + plainBlock)));
  }
  return out.takeBytes();
}

/// Independent decrypt+verify of a secured OPN frame (mirrors the receive side).
Uint8List _asymDecryptVerify({
  required RSAPrivateKey decKey,
  required RSAPublicKey verifyKey,
  required Uint8List frame,
}) {
  const cipherBlock = 256;
  const sigSize = 256;

  final hdr = parseChunkHeader(frame);
  final rawHeader = Uint8List.sublistView(frame, 0, hdr.securityHeaderEnd);
  final enc = Uint8List.sublistView(frame, hdr.securityHeaderEnd, hdr.size);

  final dec = BytesBuilder(copy: true);
  for (var i = 0; i < enc.length; i += cipherBlock) {
    dec.add(rsaOaepSha1Decrypt(decKey, Uint8List.sublistView(enc, i, i + cipherBlock)));
  }
  final plain = dec.takeBytes();
  final signedEnd = plain.length - sigSize;
  final sig = Uint8List.sublistView(plain, signedEnd);
  final signed = Uint8List(rawHeader.length + signedEnd);
  signed.setRange(0, rawHeader.length, rawHeader);
  signed.setRange(rawHeader.length, signed.length, plain);
  expect(rsaPkcs1Sha256Verify(verifyKey, signed, sig), isTrue);

  final padByte = plain[signedEnd - 1];
  final bodyEnd = signedEnd - (padByte + 1);
  return Uint8List.fromList(Uint8List.sublistView(plain, 0, bodyEnd));
}
