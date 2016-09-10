//
//  Router.swift
//  Kakapo
//
//  Created by Joan Romano on 31/03/16.
//  Copyright © 2016 devlucky. All rights reserved.
//

import Foundation

/**
 A RouteHandler used when registering different HTTP methods, which can return any Serializable object.
 
 By default, though, the Router will return a 200 status code and `["Content-Type": "application/json"]` header fields when only returning a Serializable object.
 In order to customize that behavior, check `ResponseFieldsProvider` to provide custom status code and header fields.
 */
public typealias RouteHandler = (Request) -> Serializable?

/**
 A Request struct used in `RouteHandlers` to provide valid requests.
 */
public struct Request {
    /// The decomposed URLInfo components
    public let components: [String : String]
    
    /// The decomposed URLInfo query parameters
    public let queryParameters: [URLQueryItem]
    
    /// An optional request body
    public let HTTPBody: Data?
    
    /// An optional dictionary holding the request header fields
    public let HTTPHeaders: [String: String]?
}

/**
 A protocol to adopt when a `Serializable object needs to also provide response status code and/or headerFields
 For example you may use `Response` to wrap your `Serializable` object to just achieve the result or directly implement the protocol.
 For example `JSONAPISerializer` implement the protocol in order to be able to provide custom status code in the response.
 */
public protocol ResponseFieldsProvider: CustomSerializable {
    /// The response status code
    var statusCode: Int { get }
    
    /// The Serializable body object
    var body: Serializable { get }

    /// An optional dictionary holding the response header fields
    var headerFields: [String : String]? { get }
}

extension ResponseFieldsProvider {
    
    /// The default implementation just return the serialized body.
    public func customSerialize(_ keyTransformer: KeyTransformer?) -> AnyObject? {
        return body.serialize(keyTransformer)
    }
}

/**
 A ResponseFieldsProvider implementation which can be used in `RouteHandlers` to provide valid responses that can return different status code than the default (200) or headerFields.
 
 The struct provides, apart from a Serializable `body` object, a status code and header fields.
 */
public struct Response: ResponseFieldsProvider {
    /// The response status code
    public let statusCode: Int
    
    /// The Serializable body object
    public let body: Serializable
    
    /// An optional dictionary holding the response header fields
    public let headerFields: [String : String]?
    
    /**
     Initialize `Response` object that wraps another `Serializable` object for the serialization but, implementing `ResponseFieldsProvider` can affect some parameters of the HTTP response
     
     - parameter statusCode:   the status code that the response should provide to the HTTP response
     - parameter body:         the body that will be serialized
     - parameter headerFields: the headerFields that the response should provide to the HTTP response
     
     - returns: A wrapper `Serializable` object that affect http requests.
     */
    public init(statusCode: Int, body: Serializable, headerFields: [String : String]? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.headerFields = headerFields
    }
}

/**
 A Router object is an object in charge of intercepting outgoing network calls in order to return custom objects. You register new Router objects by using the `register` class methods.
 
 After that, the router can be used to register different HTTP methods (GET, POST, DEL, PUT) with custom `RouteHandlers`
 */
public final class Router {
    
    fileprivate typealias Route = (method: HTTPMethod, handler: RouteHandler)
    
    fileprivate enum HTTPMethod: String {
        case GET, POST, PUT, DELETE
    }
    
    fileprivate var routes: [String : Route] = [:]

    /// The `baseURL` of the Router
    public let baseURL: String
    
    /// The desired latency (in seconds) to delay the mocked responses. Default value is 0.
    public var latency: TimeInterval = 0

    /**
     Register a new Router in the `KakapoServer`.
     The `baseURL` can contain a scheme, and the requestURL must match the scheme; if it doesn't contain a scheme then
     the `baseURL` is a wildcard and will be matched by any subdomain or any scheme:
     
     - base: `http://kakapo.com`, path: "any", requestURL: "http://kakapo.com/any" ✅
     - base: `http://kakapo.com`, path: "any", requestURL: "https://kakapo.com/any" ❌ because it's **https**
     - base: `kakapo.com`, path: "any", requestURL: "https://kakapo.com/any" ✅
     - base: `kakapo.com`, path: "any", requestURL: "https://api.kakapo.com/any" ✅
     
     It can also contains additional components but not wildcards:
     
     - base: `http://kakapo.com/api`, path: "any", requestURL: "http://kakapo.com/api/any" ✅
     - base: `http://kakapo.com/api/:apiversion`, path: "any", requestURL: "https://kakapo.com/api/v3/any" ❌ wildcard must be in the path used when registering a route.

     - parameter baseURL: The base URL that this Router will use
     
     - returns: An new initialized Router. Note that two Router objects can hold the same baseURL.
     */
    public class func register(_ baseURL: String) -> Router {
        return KakapoServer.register(baseURL)
    }
    
    /**
     Unregister any Routers with a given baseURL
     
     - parameter baseURL: The base URL to be unregistered
     */
    public class func unregister(_ baseURL: String) {
        KakapoServer.unregister(baseURL)
    }
    
    /**
     Disables all Routers, stopping the request intercepting
     */
    public class func disableAll() {
        KakapoServer.disable()
    }
    
    init(baseURL: String) {
        self.baseURL = baseURL
    }
    
    /**
     Immediately return false if the request's URL doesn't contain the `baseURL` otherwise true if a route matches the request
     
     - parameter request: A URL request
     
     - returns: true if a route matches the request
     */
    func canInitWithRequest(_ request: URLRequest) -> Bool {
        guard let requestURL = request.url, requestURL.absoluteString.contains(baseURL) else { return false }
        
        for (key, route) in routes where route.method.rawValue == request.httpMethod {
            if  matchRoute(baseURL, path: key, requestURL: requestURL) != nil {
                return true
            }
        }
        
        return false
    }
    
    func startLoading(_ server: KakapoServer) {
        guard let requestURL = server.request.url,
                  let client = server.client else { return }
        
        var statusCode = 200
        var headerFields: [String : String]? = ["Content-Type": "application/json"]
        var serializableObject: Serializable?
        
        for (key, route) in routes {
            if let info = matchRoute(baseURL, path: key, requestURL: requestURL) {
                // If the request body is nil use `NSURLProtocol` property see swizzling in `NSMutableURLRequest.m`
                // using a literal string because a bridging header in the podspec will be more problematic.
                let dataBody = server.request.httpBody ?? URLProtocol.property(forKey: "kkp_requestHTTPBody", in: server.request) as? Data

                let request = Request(components: info.components, queryParameters: info.queryParameters, HTTPBody: dataBody, HTTPHeaders: server.request.allHTTPHeaderFields)
                serializableObject = route.handler(request)
                break
            }
        }
        
        if let serializableObject = serializableObject as? ResponseFieldsProvider {
            statusCode = serializableObject.statusCode
            headerFields = serializableObject.headerFields
        }
        
        if let response = HTTPURLResponse(url: requestURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headerFields) {
            client.urlProtocol(server, didReceive: response, cacheStoragePolicy: .allowedInMemoryOnly)
        }
        
        if let data = serializableObject?.toData() {
            client.urlProtocol(server, didLoad: data)
        }
        
        let didFinishLoading: (URLProtocol) -> () = { (server) in
            client.urlProtocolDidFinishLoading(server)
        }

        let delayTime = DispatchTime.now() + Double(Int64(latency * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
        DispatchQueue.main.asyncAfter(deadline: delayTime) {
            // before reporting "finished", check if request has been canceled in the meantime
            if server.requestCancelled == false {
                didFinishLoading(server)
            }
        }
    }

    /**
     Registers a GET request with the given path.
     
     The path is used together with the `Router.baseURL` to match requests. It can contain wildcard components prefixed by ":" that are later used to retrieve the components of the request:
     
     - "/users/:userid" and "/users/1234" will produce [userid: 1234]
     
     Other than wildcards the components must be matched by the request.
     The path should not contain paths that are already contained in the baseURL:
     
     - base: "http://kakapo.com/api" -> path "/users/1234" ✅
     - base: "http://kakapo.com/api" -> path "api/users/1234" ❌
     
     Trailing and leading slashes are not important for the route matching.
     
     - parameter path: The path used to match URL requests.
     - parameter handler: A `RouteHandler` handler that will be used when the route is matched for a GET request
     */
    public func get(_ path: String, handler: @escaping RouteHandler) {
        routes[path] = Route(method: .GET, handler: handler)
    }
    
    /**
     Registers a POST request with the given path
     
     The path is used together with the `Router.baseURL` to match requests. It can contain wildcard components prefixed by ":" that are later used to retrieve the components of the request:
     
     - "/users/:userid" and "/users/1234" will produce [userid: 1234]
     
     Other than wildcards the components must be matched by the request.
     The path should not contain paths that are already contained in the baseURL:
     
     - base: "http://kakapo.com/api" -> path "/users/1234" ✅
     - base: "http://kakapo.com/api" -> path "api/users/1234" ❌
     
     Trailing and leading slashes are not important for the route matching.
     
     - parameter path: The path used to match URL requests.
     - parameter handler: A `RouteHandler` handler that will be used when the route is matched for a GET request
     */
    public func post(_ path: String, handler: @escaping RouteHandler) {
        routes[path] =  Route(method: .POST, handler: handler)
    }
    
    /**
     Registers a DEL request with the given path
     
     The path is used together with the `Router.baseURL` to match requests. It can contain wildcard components prefixed by ":" that are later used to retrieve the components of the request:
     
     - "/users/:userid" and "/users/1234" will produce [userid: 1234]
     
     Other than wildcards the components must be matched by the request.
     The path should not contain paths that are already contained in the baseURL:
     
     - base: "http://kakapo.com/api" -> path "/users/1234" ✅
     - base: "http://kakapo.com/api" -> path "api/users/1234" ❌
     
     Trailing and leading slashes are not important for the route matching.
     
     - parameter path: The path used to match URL requests.
     - parameter handler: A `RouteHandler` handler that will be used when the route is matched for a GET request
     */
    public func del(_ path: String, handler: @escaping RouteHandler) {
        routes[path] = Route(method: .DELETE, handler: handler)
    }
    
    /**
     Registers a PUT request with the given path
     
     The path is used together with the `Router.baseURL` to match requests. It can contain wildcard components prefixed by ":" that are later used to retrieve the components of the request:
     
     - "/users/:userid" and "/users/1234" will produce [userid: 1234]
     
     Other than wildcards the components must be matched by the request.
     The path should not contain paths that are already contained in the baseURL:
     
     - base: "http://kakapo.com/api" -> path "/users/1234" ✅
     - base: "http://kakapo.com/api" -> path "api/users/1234" ❌
     
     Trailing and leading slashes are not important for the route matching.
     
     - parameter path: The path used to match URL requests.
     - parameter handler: A `RouteHandler` handler that will be used when the route is matched for a GET request
     */
    public func put(_ path: String, handler: @escaping RouteHandler) {
        routes[path] = Route(method: .PUT, handler: handler)
    }

}
