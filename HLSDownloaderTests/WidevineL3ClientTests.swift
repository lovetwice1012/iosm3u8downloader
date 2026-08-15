import Security
import XCTest
@testable import HLSDownloader

final class WidevineL3ClientTests: XCTestCase {
    private static let now: Int64 = 1_700_000_000

    func testAESCMACMatchesPublishedNISTVectors() throws {
        let key = try data(hex: "2b7e151628aed2a6abf7158809cf4f3c")

        XCTAssertEqual(
            try WidevineL3Crypto.aesCMAC(message: Data(), key: key),
            try data(hex: "bb1d6929e95937287fa37d129b756746")
        )
        XCTAssertEqual(
            try WidevineL3Crypto.aesCMAC(
                message: data(hex: "6bc1bee22e409f96e93d7e117393172a"),
                key: key
            ),
            try data(hex: "070a16b46b4d4144f79bdd9dd04a287c")
        )

        let sessionKey = Data((0..<16).map { UInt8($0) })
        let request = try data(hex: "deadbeef01020304")
        XCTAssertEqual(
            try WidevineL3Crypto.deriveEncryptionKey(
                request: request,
                sessionKey: sessionKey
            ),
            try data(hex: "ef9bb4c7c0c07386f436cc99019967bc")
        )
        XCTAssertEqual(
            try WidevineL3Crypto.deriveAuthenticationKey(
                request: request,
                sessionKey: sessionKey
            ),
            try data(hex: "a1f068bbda60891c99e9b45c0910c22134a04c31ca4129a1e2d09ff5779a84b8")
        )
        XCTAssertEqual(
            WidevineL3Crypto.hmacSHA256(
                key: Data(repeating: 0x0B, count: 20),
                message: Data("Hi There".utf8)
            ),
            try data(hex: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        )
    }

    func testVersionOnePSSHOuterKIDIsConvertedToWidevinePayload() throws {
        let keyID = Data(repeating: 0xA5, count: 16)
        var box = Data()
        appendUInt32(52, to: &box)
        box.append(Data("pssh".utf8))
        box.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        box.append(contentsOf: [
            0xED, 0xEF, 0x8B, 0xA9, 0x79, 0xD6, 0x4A, 0xCE,
            0xA3, 0xC8, 0x27, 0xDC, 0xD5, 0x1D, 0x21, 0xED
        ])
        appendUInt32(1, to: &box)
        box.append(keyID)
        appendUInt32(0, to: &box)

        let payload = try WidevinePSSH.payload(from: box, maximumBytes: 1_024)
        XCTAssertEqual(try WidevinePSSH.keyIDs(fromPayload: payload), Set([keyID]))
    }

    func testAndroidWVDUsesUppercaseHexRequestID() throws {
        let fixture = try makeFixture()
        var externalError: Unmanaged<CFError>?
        let encodedPrivateKey = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(fixture.privateKey, &externalError) as Data?
        )
        let client = try WidevineL3Client(
            wvdData: makeWVD(
                deviceType: .android,
                privateKey: encodedPrivateKey,
                clientIdentification: try makeClientIdentification(
                    publicKey: fixture.publicKey
                )
            ),
            clock: { Self.now },
            randomBytes: { count in Data(repeating: 0xAB, count: count) }
        )

        let challenge = try client.makeLicenseChallenge(
            psshData: makePSSHPayload(keyID: Data(repeating: 0x11, count: 16))
        )
        XCTAssertEqual(challenge.requestID.count, 32)
        XCTAssertEqual(
            String(decoding: challenge.requestID, as: UTF8.self),
            "ABABABAB000000000100000000000000"
        )
    }

    func testRejectsWVDWhenCertificateAndPrivateKeyDoNotMatch() throws {
        let first = try makeFixture()
        let second = try makeFixture()
        var externalError: Unmanaged<CFError>?
        let encodedPrivateKey = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(first.privateKey, &externalError) as Data?
        )
        let wvd = makeWVD(
            privateKey: encodedPrivateKey,
            clientIdentification: try makeClientIdentification(publicKey: second.publicKey)
        )

        XCTAssertThrowsError(try WidevineL3Client(wvdData: wvd)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .credentialKeyMismatch)
        }
    }

    func testTransportRequestEncodesOnlyExplicitWrappers() throws {
        let challenge = Data([0xFB, 0xFF])
        let url = try XCTUnwrap(URL(string: "https://license.example.test/widevine"))
        let secretHeader = "secret-header-value"
        let redactedRequest = WidevineLicenseTransportRequest(
            serverURL: url,
            requestData: challenge,
            headers: ["Authorization": secretHeader]
        )
        let reflected = String(reflecting: redactedRequest)
        var dumped = ""
        dump(redactedRequest, to: &dumped)
        XCTAssertFalse(reflected.contains(secretHeader))
        XCTAssertFalse(reflected.contains(challenge.base64EncodedString()))
        XCTAssertFalse(dumped.contains(secretHeader))
        XCTAssertFalse(dumped.contains(challenge.base64EncodedString()))

        XCTAssertEqual(
            try WidevineLicenseTransportRequest(
                serverURL: url,
                requestData: challenge
            ).encodedBody(),
            challenge
        )

        let json = try WidevineLicenseTransportRequest(
            serverURL: url,
            requestData: challenge,
            contentType: "application/json",
            bodyEncoding: .jsonBase64(fieldName: "challenge")
        ).encodedBody()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: String]
        )
        XCTAssertEqual(object, ["challenge": "+/8="])

        let form = try WidevineLicenseTransportRequest(
            serverURL: url,
            requestData: challenge,
            contentType: "application/x-www-form-urlencoded",
            bodyEncoding: .formURLEncodedBase64(fieldName: "challenge")
        ).encodedBody()
        XCTAssertEqual(String(decoding: form, as: UTF8.self), "challenge=%2B%2F8%3D")

        XCTAssertThrowsError(
            try WidevineLicenseTransportRequest(
                serverURL: url,
                requestData: challenge,
                bodyEncoding: .jsonBase64(fieldName: "bad field")
            ).encodedBody()
        ) { error in
            XCTAssertEqual(error as? WidevineLicenseTransportError, .invalidWrapperFieldName)
        }
    }

    func testKeyAcquirerRejectsHTTPAndDoesNotGuessObservedJSONWrapper() async throws {
        let acquirer = WidevineL3KeyAcquirer(transport: UnexpectedLicenseTransport())
        let pssh = makePSSHPayload(keyID: Data(repeating: 0x08, count: 16))
        do {
            _ = try await acquirer.acquireKeys(
                initData: [pssh],
                expectedKeyIDs: [],
                licenseConfiguration: WidevineLicenseConfiguration(
                    serverURL: try XCTUnwrap(URL(string: "http://license.example.test/widevine"))
                ),
                wvdData: Data()
            )
            XCTFail("HTTP license endpoints must be rejected")
        } catch {
            XCTAssertEqual(error as? WidevineL3KeyAcquirerError, .insecureLicenseURL)
        }

        do {
            _ = try await acquirer.acquireKeys(
                initData: [pssh],
                expectedKeyIDs: [],
                licenseConfiguration: WidevineLicenseConfiguration(
                    serverURL: try XCTUnwrap(
                        URL(string: "https://widevine.sprink.cloud/license/widevine")
                    ),
                    observedRequestMetadata: WidevineLicenseRequestMetadata(
                        method: "POST",
                        contentType: "application/json",
                        headerNames: ["content-type"],
                        bodyKind: .json,
                        bodyByteCount: 123,
                        source: .emeCorrelatedFetch
                    )
                ),
                wvdData: Data()
            )
            XCTFail("A JSON field name must not be guessed")
        } catch {
            XCTAssertEqual(error as? WidevineL3KeyAcquirerError, .unsafeWrapperInference)
        }
    }

    func testChallengeIsPSSSignedAndAuthenticatedLicenseDecryptsContentKey() throws {
        let fixture = try makeFixture()
        let keyID = Data((0..<16).map { UInt8($0) })
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(psshData: makePSSHPayload(keyID: keyID))

        let signedRequest = try WidevineSignedMessage.parse(challenge.requestData)
        XCTAssertEqual(signedRequest.type, 1)
        XCTAssertEqual(signedRequest.message, challenge.licenseRequestData)
        let signature = try XCTUnwrap(signedRequest.signature)
        XCTAssertTrue(
            SecKeyVerifySignature(
                fixture.publicKey,
                .rsaSignatureMessagePSSSHA1,
                challenge.licenseRequestData as CFData,
                signature as CFData,
                nil
            )
        )

        let fields = try protobufFields(challenge.licenseRequestData)
        XCTAssertEqual(fields[3]?.varint, 1)
        XCTAssertEqual(fields[4]?.varint, UInt64(Self.now))
        XCTAssertEqual(fields[6]?.varint, 21)
        XCTAssertNotNil(fields[1]?.bytes)
        let contentIdentification = try XCTUnwrap(fields[2]?.bytes)
        let contentFields = try protobufFields(contentIdentification)
        let requestPSSH = try XCTUnwrap(contentFields[1]?.bytes)
        let psshFields = try protobufFields(requestPSSH)
        XCTAssertEqual(psshFields[1]?.bytes, makePSSHPayload(keyID: keyID))
        XCTAssertEqual(psshFields[2]?.varint, WidevineLicenseType.offline.rawValue)
        XCTAssertEqual(psshFields[3]?.bytes?.count, 16)

        let expectedKey = Data(repeating: 0xC7, count: 16)
        let response = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: expectedKey
        )
        XCTAssertEqual(try WidevineLicenseResponseEnvelope.unwrap(response), response)
        XCTAssertEqual(
            try WidevineLicenseResponseEnvelope.unwrap(
                Data(response.base64EncodedString().utf8)
            ),
            response
        )
        let jsonResponse = try JSONSerialization.data(
            withJSONObject: ["license": response.base64EncodedString()]
        )
        XCTAssertEqual(try WidevineLicenseResponseEnvelope.unwrap(jsonResponse), response)
        let keys = try client.parseLicense(response, for: challenge)

        XCTAssertEqual(
            keys,
            [WidevineContentKey(id: keyID, value: expectedKey, type: .content)]
        )
    }

    func testTamperedLicenseAuthenticationIsRejected() throws {
        let fixture = try makeFixture()
        let keyID = Data(repeating: 0x11, count: 16)
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(psshData: makePSSHPayload(keyID: keyID))
        let response = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x22, count: 16)
        )
        let parsed = try WidevineSignedMessage.parse(response)
        var tamperedSignature = try XCTUnwrap(parsed.signature)
        tamperedSignature[tamperedSignature.startIndex] ^= 0x01
        var tamperedResponse = WidevineProtobufWriter()
        tamperedResponse.appendVarint(field: 1, value: try XCTUnwrap(parsed.type))
        tamperedResponse.appendBytes(field: 2, value: try XCTUnwrap(parsed.message))
        tamperedResponse.appendBytes(field: 3, value: tamperedSignature)
        tamperedResponse.appendBytes(field: 4, value: try XCTUnwrap(parsed.sessionKey))
        tamperedResponse.appendVarint(field: 8, value: try XCTUnwrap(parsed.sessionKeyType))
        if let core = parsed.oemcryptoCoreMessage {
            tamperedResponse.appendBytes(field: 9, value: core)
        }

        XCTAssertThrowsError(try client.parseLicense(tamperedResponse.data, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .responseAuthenticationFailed)
        }
    }

    func testAmbiguousJSONLicenseEnvelopeIsRejected() throws {
        let fixture = try makeFixture()
        let keyID = Data(repeating: 0x09, count: 16)
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(psshData: makePSSHPayload(keyID: keyID))
        let response = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x19, count: 16)
        )
        let base64 = response.base64EncodedString()
        let ambiguous = try JSONSerialization.data(
            withJSONObject: ["license": base64, "response": base64]
        )

        XCTAssertThrowsError(try WidevineLicenseResponseEnvelope.unwrap(ambiguous)) { error in
            XCTAssertEqual(error as? WidevineL3KeyAcquirerError, .invalidResponseEnvelope)
        }
    }

    func testHardwareSecureContentKeyIsRejected() throws {
        let fixture = try makeFixture()
        let keyID = Data(repeating: 0x31, count: 16)
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(psshData: makePSSHPayload(keyID: keyID))
        let response = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x41, count: 16),
            securityLevel: 3
        )

        XCTAssertThrowsError(try client.parseLicense(response, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unsupportedKeySecurityLevel)
        }
    }

    func testSoftwareSecureDecodeAndOEMContentKeysAreRejected() throws {
        let fixture = try makeFixture()
        let keyID = Data(repeating: 0x39, count: 16)
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(psshData: makePSSHPayload(keyID: keyID))

        let levelTwo = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x42, count: 16),
            securityLevel: 2
        )
        XCTAssertThrowsError(try client.parseLicense(levelTwo, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unsupportedKeySecurityLevel)
        }

        let oemContent = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x43, count: 16),
            keyType: WidevineContentKeyType.oemContent.rawValue
        )
        XCTAssertThrowsError(try client.parseLicense(oemContent, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unsupportedKeyType)
        }
    }

    func testDeniedBoundedAndUnexpectedKeyLicensesAreRejected() throws {
        let fixture = try makeFixture()
        let requestedKeyID = Data(repeating: 0x51, count: 16)
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(
            psshData: makePSSHPayload(keyID: requestedKeyID)
        )

        let denied = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: requestedKeyID,
            contentKey: Data(repeating: 0x61, count: 16),
            canPlay: false
        )
        XCTAssertThrowsError(try client.parseLicense(denied, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .playbackNotAllowed)
        }

        let bounded = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: requestedKeyID,
            contentKey: Data(repeating: 0x62, count: 16),
            licenseDuration: 5
        )
        XCTAssertThrowsError(try client.parseLicense(bounded, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unsupportedPolicyConstraint)
        }

        let unexpected = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: Data(repeating: 0x71, count: 16),
            contentKey: Data(repeating: 0x72, count: 16)
        )
        XCTAssertThrowsError(try client.parseLicense(unexpected, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unexpectedKeyID)
        }
    }

    func testPersistenceRequestIDAndKeyConstraintsAreFailClosed() throws {
        let fixture = try makeFixture()
        let keyID = Data(repeating: 0x73, count: 16)
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(psshData: makePSSHPayload(keyID: keyID))

        let notPersistent = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x74, count: 16),
            canPersist: false
        )
        XCTAssertThrowsError(try client.parseLicense(notPersistent, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .persistenceNotAllowed)
        }

        let wrongRequest = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x75, count: 16),
            responseRequestID: Data(repeating: 0xFF, count: 16)
        )
        XCTAssertThrowsError(try client.parseLicense(wrongRequest, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .requestIDMismatch)
        }

        let protectedOutput = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x76, count: 16),
            hasKeyConstraint: true
        )
        XCTAssertThrowsError(try client.parseLicense(protectedOutput, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unsupportedKeyConstraint)
        }

        let srmConstrained = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x77, count: 16),
            unsupportedLicenseField: 8
        )
        XCTAssertThrowsError(try client.parseLicense(srmConstrained, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unsupportedPolicyConstraint)
        }

        let futureConstrained = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x78, count: 16),
            unsupportedLicenseField: 99
        )
        XCTAssertThrowsError(try client.parseLicense(futureConstrained, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .unsupportedPolicyConstraint)
        }

        XCTAssertFalse(WidevineL3Client.supportsPrivacyMode)
        var serviceCertificate = WidevineProtobufWriter()
        serviceCertificate.appendVarint(field: 1, value: 5)
        XCTAssertThrowsError(
            try client.parseLicense(serviceCertificate.data, for: challenge)
        ) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .privacyModeUnsupported)
        }
    }

    func testDuplicateContentKIDIsRejected() throws {
        let fixture = try makeFixture()
        let keyID = Data(repeating: 0x81, count: 16)
        let client = try makeClient(privateKey: fixture.privateKey)
        let challenge = try client.makeLicenseChallenge(psshData: makePSSHPayload(keyID: keyID))
        let response = try makeLicenseResponse(
            challenge: challenge,
            publicKey: fixture.publicKey,
            keyID: keyID,
            contentKey: Data(repeating: 0x82, count: 16),
            duplicateKey: true
        )

        XCTAssertThrowsError(try client.parseLicense(response, for: challenge)) { error in
            XCTAssertEqual(error as? WidevineL3ClientError, .duplicateKeyID)
        }
    }

    private func makeClient(privateKey: SecKey) throws -> WidevineL3Client {
        var externalError: Unmanaged<CFError>?
        let encodedPrivateKey = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(privateKey, &externalError) as Data?
        )
        let wvd = makeWVD(
            privateKey: encodedPrivateKey,
            clientIdentification: try makeClientIdentification(
                publicKey: try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
            )
        )
        return try WidevineL3Client(
            wvdData: wvd,
            clock: { Self.now },
            randomBytes: { count in Data(repeating: UInt8(count), count: count) }
        )
    }

    private func makeFixture() throws -> (privateKey: SecKey, publicKey: SecKey) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(
            SecKeyCreateRandomKey(attributes as CFDictionary, &error)
        )
        return (privateKey, try XCTUnwrap(SecKeyCopyPublicKey(privateKey)))
    }

    private func makeLicenseResponse(
        challenge: WidevineLicenseChallenge,
        publicKey: SecKey,
        keyID: Data,
        contentKey: Data,
        keyType: UInt64 = WidevineContentKeyType.content.rawValue,
        securityLevel: UInt64 = 1,
        canPlay: Bool = true,
        canPersist: Bool = true,
        licenseStartTime: UInt64 = UInt64(WidevineL3ClientTests.now),
        licenseDuration: UInt64 = 0,
        duplicateKey: Bool = false,
        responseRequestID: Data? = nil,
        hasKeyConstraint: Bool = false,
        unsupportedLicenseField: Int? = nil
    ) throws -> Data {
        let sessionKey = Data(repeating: 0xA1, count: 16)
        let iv = Data(repeating: 0xB2, count: 16)
        let encryptionKey = try WidevineL3Crypto.deriveEncryptionKey(
            request: challenge.licenseRequestData,
            sessionKey: sessionKey
        )
        let encryptedContentKey = try WidevineL3Crypto.encryptAESCBCPKCS7(
            contentKey,
            key: encryptionKey,
            iv: iv
        )

        var keyContainer = WidevineProtobufWriter()
        keyContainer.appendBytes(field: 1, value: keyID)
        keyContainer.appendBytes(field: 2, value: iv)
        keyContainer.appendBytes(field: 3, value: encryptedContentKey)
        keyContainer.appendVarint(field: 4, value: keyType)
        keyContainer.appendVarint(field: 5, value: securityLevel)
        if hasKeyConstraint {
            keyContainer.appendMessage(field: 6, value: Data())
        }

        var policy = WidevineProtobufWriter()
        policy.appendVarint(field: 1, value: canPlay ? 1 : 0)
        policy.appendVarint(field: 2, value: canPersist ? 1 : 0)
        policy.appendVarint(field: 6, value: licenseDuration)

        var identification = WidevineProtobufWriter()
        identification.appendBytes(
            field: 1,
            value: responseRequestID ?? challenge.requestID
        )
        identification.appendVarint(field: 4, value: WidevineLicenseType.offline.rawValue)

        var license = WidevineProtobufWriter()
        license.appendMessage(field: 1, value: identification.data)
        license.appendMessage(field: 2, value: policy.data)
        license.appendMessage(field: 3, value: keyContainer.data)
        if duplicateKey {
            license.appendMessage(field: 3, value: keyContainer.data)
        }
        license.appendVarint(field: 4, value: licenseStartTime)
        if let unsupportedLicenseField {
            license.appendVarint(field: unsupportedLicenseField, value: 1)
        }

        let authenticationKey = try WidevineL3Crypto.deriveAuthenticationKey(
            request: challenge.licenseRequestData,
            sessionKey: sessionKey
        )
        let oemcryptoCoreMessage = Data([0x10, 0x20, 0x30])
        let hmac = WidevineL3Crypto.hmacSHA256(
            key: authenticationKey,
            message: oemcryptoCoreMessage + license.data
        )
        var encryptionError: Unmanaged<CFError>?
        let wrappedSessionKey = try XCTUnwrap(
            SecKeyCreateEncryptedData(
                publicKey,
                .rsaEncryptionOAEPSHA1,
                sessionKey as CFData,
                &encryptionError
            ) as Data?
        )

        var response = WidevineProtobufWriter()
        response.appendVarint(field: 1, value: 2)
        response.appendBytes(field: 2, value: license.data)
        response.appendBytes(field: 3, value: hmac)
        response.appendBytes(field: 4, value: wrappedSessionKey)
        response.appendVarint(field: 8, value: 1)
        response.appendBytes(field: 9, value: oemcryptoCoreMessage)
        return response.data
    }

    private func makePSSHPayload(keyID: Data) -> Data {
        var payload = WidevineProtobufWriter()
        payload.appendBytes(field: 2, value: keyID)
        return payload.data
    }

    private func makeWVD(
        deviceType: WVDFileDeviceType = .chrome,
        privateKey: Data,
        clientIdentification: Data
    ) -> Data {
        precondition(privateKey.count <= Int(UInt16.max))
        precondition(clientIdentification.count <= Int(UInt16.max))
        var result = Data([
            0x57, 0x56, 0x44, 0x02, deviceType.rawValue, 0x03, 0x00
        ])
        appendUInt16(UInt16(privateKey.count), to: &result)
        result.append(privateKey)
        appendUInt16(UInt16(clientIdentification.count), to: &result)
        result.append(clientIdentification)
        return result
    }

    private func makeClientIdentification(publicKey: SecKey) throws -> Data {
        var externalError: Unmanaged<CFError>?
        let encodedPublicKey = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(publicKey, &externalError) as Data?
        )
        var certificate = WidevineProtobufWriter()
        certificate.appendBytes(field: 5, value: encodedPublicKey)
        var signedCertificate = WidevineProtobufWriter()
        signedCertificate.appendMessage(field: 1, value: certificate.data)
        var clientIdentification = WidevineProtobufWriter()
        clientIdentification.appendMessage(field: 1, value: signedCertificate.data)
        return clientIdentification.data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func protobufFields(_ data: Data) throws -> [Int: WidevineProtobufField] {
        var reader = try WidevineProtobufReader(data)
        var result: [Int: WidevineProtobufField] = [:]
        while let field = try reader.next() {
            result[field.number] = field
        }
        return result
    }

    private func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw TestError.invalidHex
        }
        var result = Data()
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else {
                throw TestError.invalidHex
            }
            result.append(byte)
            index = end
        }
        return result
    }

    private enum TestError: Error {
        case invalidHex
    }
}

private struct UnexpectedLicenseTransport: WidevineLicenseTransporting {
    func send(_ request: WidevineLicenseTransportRequest) async throws -> Data {
        throw URLError(.cannotConnectToHost)
    }
}
