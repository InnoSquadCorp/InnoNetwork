package com.innosquad.innonetwork.consumersmoke.`when`

import com.innosquad.innonetwork.client.codegen.InnoEndpoint
import com.innosquad.innonetwork.client.codegen.InnoHttpMethod

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/request")
public class Request

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/response")
public class Response

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/output")
public class Output

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/keyword")
public class `class`

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/messages/")
public class TrailingSlashEndpoint

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/int")
public class Int

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/package-name")
public class com

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/alias-name")
public class InnoNetworkNativeRequest
