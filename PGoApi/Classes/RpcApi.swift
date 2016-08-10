//
//  RPC.swift
//  pgomap
//
//  Based on https://github.com/tejado/pgoapi/blob/master/pgoapi/rpc_api.py
//
//  Created by Luke Sapan on 7/20/16.
//  Copyright © 2016 Coadstal. All rights reserved.
//

import Foundation
import Alamofire
import ProtocolBuffers


class PGoRpcApi {
    let intent: PGoApiIntent
    let auth: PGoAuth
    let delegate: PGoApiDelegate?
    let subrequests: [PGoApiMethod]
    let api: PGoApiRequest
    let encrypt: PGoEncrypt
    private var timeSinceStart:UInt64 = 0
    private var locationHex: NSData
    private var requestId: UInt64 = 8145806132888207460
    
    init(subrequests: [PGoApiMethod], intent: PGoApiIntent, auth: PGoAuth, api: PGoApiRequest, delegate: PGoApiDelegate?) {
        // TODO: Eventually use a custom session
        // Add "Niantic App" as the User-Agent
        let manager = Manager.sharedInstance
        manager.session.configuration.HTTPAdditionalHeaders = [
            "User-Agent": "Niantic App"
        ]
        
        self.subrequests = subrequests
        self.intent = intent
        self.auth = auth
        self.delegate = delegate
        self.api = api
        self.timeSinceStart = UInt64(NSDate().timeIntervalSince1970 * 1000.0)
        self.locationHex = NSData()
        self.encrypt = PGoEncrypt()
        self.requestId = randomUInt64(UInt64(pow(Double(2),Double(62))), max: UInt64(pow(Double(2),Double(63))))
    }
    
    func request() {
        // TODO: Eventually update this function to take playerPosition, and pass to buildMainRequest
        let requestData = buildMainRequest().data()
        
        Alamofire.request(.POST, auth.endpoint, parameters: [:], encoding: .Custom({
            (convertible, params) in
            let mutableRequest = convertible.URLRequest.copy() as! NSMutableURLRequest
            mutableRequest.HTTPBody = requestData
            return (mutableRequest, nil)
        })).responseData { response in
            let statusCode = response.response?.statusCode
            if statusCode != 200 {
                print("Unexpected response code, should be 200, got \(statusCode)")
                self.delegate?.didReceiveApiError(self.intent, statusCode: statusCode)
                return
            }
            
            print("Got a response!")
            self.delegate?.didReceiveApiResponse(self.intent, response: self.parseMainResponse(response.result.value!))
        }
    }
    
    private func locationToHex(value:Double) -> NSData {
        
        let f2d = String(unsafeBitCast(value, UInt64.self), radix: 16)
        let s = f2d.uppercaseString.stringByReplacingOccurrencesOfString(" ", withString: "")
        
        let data = NSMutableData(capacity: s.characters.count / 2)
        
        for i in 0.stride(to:s.characters.count, by:2) {
            var x = -(s.characters.count) + i + 2
            if x > s.characters.count - 2 {
                x = s.characters.count - x
                if (x < 0) {
                    x = 0
                }
            }
            let r = s.startIndex.advancedBy(i)..<s.endIndex.advancedBy(x)
            let substring = s[r]
            
            let byte = UInt8(substring.withCString { strtoul($0, nil, 16) })
            data?.appendBytes([byte] as [UInt8], length: 1)
        }
        
        return data!
    }

    private func hashAuthTicket() -> UInt32 {
        let xxh32:xxhash = xxhash(seed: 0x1B845238)
        xxh32.update(Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(auth.authToken!.data().bytes), count: auth.authToken!.data().length)))
        let firstHash = xxh32.digest()
        
        let xxh32_2:xxhash = xxhash(seed: firstHash)
        
        xxh32_2.update(Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(self.locationHex.bytes), count: self.locationHex.length)))
        return xxh32_2.digest()
    }
    
    private func hashLocation() -> UInt32 {
        let xxh32:xxhash = xxhash(seed: 0x1B845238)
        
        let LocationData = NSMutableData()
        LocationData.appendData(locationToHex(self.api.Location.lat))
        LocationData.appendData(locationToHex(self.api.Location.long))
        if self.api.Location.alt == nil {
            LocationData.appendData(locationToHex(0))
        } else {
            LocationData.appendData(locationToHex(self.api.Location.alt!))
        }
        
        self.locationHex = LocationData
        
        xxh32.update(Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(LocationData.bytes), count: LocationData.length)))
        return xxh32.digest()
    }
    
    private func randomUInt64(min: UInt64, max: UInt64) -> UInt64 {
        return UInt64(Double(max - min) * drand48() + Double(min))
    }
    
    private func hashRequest(requestData:NSData) -> UInt64 {
        let xxh64:xxhash = xxhash(seed: 0x1B845238)
        let firstHash = xxh64.xxh64(0x1B845238, input: Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(auth.authToken!.data().bytes), count: auth.authToken!.data().length)))
        return xxh64.xxh64(firstHash, input: Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(requestData.bytes), count: requestData.length)))
    }
    
    private func buildMainRequest() -> Pogoprotos.Networking.Envelopes.RequestEnvelope {
        
        print("Generating main request...")
        
        let requestBuilder = Pogoprotos.Networking.Envelopes.RequestEnvelope.Builder()
        requestBuilder.statusCode = 2
        requestBuilder.requestId = self.requestId
        print(self.requestId)
        requestBuilder.unknown12 = 989
        
        requestBuilder.latitude = self.api.Location.lat
        requestBuilder.longitude = self.api.Location.long
        if self.api.Location.alt != nil {
            requestBuilder.altitude = self.api.Location.alt!
        }
        
        if (auth.authToken == nil) {
            let authInfoBuilder = requestBuilder.getAuthInfoBuilder()
            let authInfoTokenBuilder = authInfoBuilder.getTokenBuilder()
            authInfoBuilder.provider = auth.authType.description
            authInfoTokenBuilder.contents = auth.accessToken!
            authInfoTokenBuilder.unknown2 = 59
        } else {
            requestBuilder.authTicket = auth.authToken!
            
            let signatureBuilder = Pogoprotos.Networking.Envelopes.Signature.Builder()
            signatureBuilder.locationHash2 = hashLocation()
            signatureBuilder.locationHash1 = hashAuthTicket()
            for request in requestBuilder.requests {
                let h64 = hashRequest(request.data())
                signatureBuilder.requestHash.append(h64)
            }
            
            signatureBuilder.unknown22 = self.encrypt.randomBytes()
            
            signatureBuilder.timestamp = UInt64(NSDate().timeIntervalSince1970 * 1000.0)
            signatureBuilder.timestampSinceStart = timeSinceStart
            
            let signature = try! signatureBuilder.build()
            
            let unknown6 = Pogoprotos.Networking.Envelopes.Unknown6.Builder()
            unknown6.requestType = 6
            
            let unknown2 = requestBuilder.getUnknown6Builder().getUnknown2Builder()
            
            unknown2.encryptedSignature = self.encrypt.encryptUsingLib(signature.data())
        }
        
        print("Generating subrequests...")
        for subrequest in subrequests {
            print("Processing \(subrequest)...")
            let subrequestBuilder = Pogoprotos.Networking.Requests.Request.Builder()
            subrequestBuilder.requestType = subrequest.id
            subrequestBuilder.requestMessage = subrequest.message.data()
            requestBuilder.requests += [try! subrequestBuilder.build()]
        }
        
        self.requestId += 1
        
        print("Building request...")
        return try! requestBuilder.build()
    }
    
    private func parseMainResponse(data: NSData) -> PGoApiResponse {
        print("Parsing main response...")
        
        let response = try! Pogoprotos.Networking.Envelopes.ResponseEnvelope.parseFromData(data)
        let subresponses = parseSubResponses(response)
        return PGoApiResponse(response: response, subresponses: subresponses)
    }
    
    private func parseSubResponses(response: Pogoprotos.Networking.Envelopes.ResponseEnvelope) -> [GeneratedMessage] {
        print("Parsing subresponses...")
        
        var subresponses: [GeneratedMessage] = []
        for (idx, subresponseData) in response.returns.enumerate() {
            let subrequest = subrequests[idx]
            subresponses.append(subrequest.parser(subresponseData))
        }
        return subresponses
    }
    
}