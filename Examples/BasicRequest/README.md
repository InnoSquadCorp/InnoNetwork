# Basic Request Examples

This example demonstrates how to make basic HTTP requests (GET, POST, PUT, PATCH, DELETE) using InnoNetwork.

## Setup

First, configure the API:

```swift
import InnoNetwork

let configuration = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)

let client = DefaultNetworkClient(configuration: configuration)
```

## Running the Examples

To run these examples:

1. Add InnoNetwork package to your project
2. Copy the example code into a Swift file
3. Import InnoNetwork
4. Run the code

Or directly execute the example file as a Swift script:

```bash
swift BasicRequestExample.swift
```

## Covered Scenarios

This example covers:

1. **GET Request**: Fetch all todos
2. **GET Single Item**: Fetch a specific post by ID
3. **POST Request**: Create a new post
4. **PUT Request**: Full update of a post
5. **PATCH Request**: Partial update of a post
6. **DELETE Request**: Delete a post
7. **Form URL-encoded Request**: Login with form data
8. **Multipart/Form-data Upload**: File upload with multipart form data

## Note

These examples use JSONPlaceholder (https://jsonplaceholder.typicode.com), a free online REST API for testing and prototyping.

## Key Concepts

### API Definition

Each API endpoint is defined as a `struct` or `actor` conforming to `APIDefinition`:

```swift
struct GetTodos: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = [Todo]

    var method: HTTPMethod { .get }
    var path: String { "/todos" }
}
```

### Making Requests

Use the `DefaultNetworkClient` to make requests:

```swift
let client = DefaultNetworkClient(configuration: configuration)
let todos = try await client.request(GetTodos())
```

### With Parameters

For requests with parameters:

```swift
struct CreatePost: APIDefinition {
    struct PostParameter: Encodable, Sendable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    let parameters: PostParameter?
    var method: HTTPMethod { .post }
    var path: String { "/posts" }

    init(title: String, body: String, userId: Int = 1) {
        self.parameters = PostParameter(title: title, body: body, userId: userId)
    }
}

// Usage
let newPost = try await client.request(CreatePost(
    title: "My New Post",
    body: "This is the content of my new post"
))
```

### Form URL-encoded

For form-encoded requests:

```swift
struct LoginRequest: APIDefinition {
    struct LoginParameter: Encodable, Sendable {
        let email: String
        let password: String
    }

    typealias Parameter = LoginParameter
    typealias APIResponse = AuthResponse

    let parameters: LoginParameter?
    var method: HTTPMethod { .post }
    var path: String { "/login" }
    var contentType: ContentType { .formUrlEncoded }

    init(email: String, password: String) {
        self.parameters = LoginParameter(email: email, password: password)
    }
}

let authResponse = try await client.request(LoginRequest(
    email: "user@example.com",
    password: "password123"
))
```

### Multipart/Form-data (File Upload)

For file uploads:

```swift
struct UploadImage: MultipartAPIDefinition {
    typealias APIResponse = UploadResponse

    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData()
        formData.append("My Image", name: "title")
        formData.append("1", name: "userId")
        formData.append(
            imageData,
            name: "image",
            fileName: "image.jpg",
            mimeType: "image/jpeg"
        )
        return formData
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
}

let response = try await client.upload(UploadImage())
```
