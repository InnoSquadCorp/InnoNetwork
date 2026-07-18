# Basic Request Examples

This example demonstrates how to make basic HTTP requests (GET, POST, PUT, PATCH, DELETE) using InnoNetwork.

## Setup

For a client that needs no custom policy, provide only the base URL:

```swift
import InnoNetwork

let client = DefaultNetworkClient(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)
```

This initializer uses `NetworkConfiguration.safeDefaults(baseURL:)`. Switch to
the configuration initializer only when the integration needs an explicit
policy.

## Running the Examples

To use these examples:

1. Add InnoNetwork package to your project
2. Copy the example code into a Swift file
3. Import InnoNetwork
4. Run the code

From the repository root, maintainers can compile the copyable source against
the current package with the stable-example contract:

```bash
bash Scripts/check_stable_examples.sh
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

Each named endpoint remains an explicit struct. The default-enabled macro
derives `APIDefinition` conformance and validates the method, path, payload,
response, and authentication contract:

```swift
@APIDefinition(method: .get, path: "/todos", auth: .anonymous)
struct GetTodos {
    typealias APIResponse = [Todo]
}
```

Use a manual conformance only when the endpoint needs a shape the macro cannot
derive; manual endpoints must declare `sessionAuthentication` explicitly.

### Making Requests

Use the `DefaultNetworkClient` to make requests:

```swift
let client = DefaultNetworkClient(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)
let todos = try await client.request(GetTodos())
```

### With Parameters

For requests with parameters:

```swift
@APIDefinition(method: .post, path: "/posts", auth: .anonymous)
struct CreatePost {
    struct PostParameter: Encodable, Sendable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias APIResponse = Post

    let body: PostParameter

    init(title: String, body: String, userId: Int = 1) {
        self.body = PostParameter(title: title, body: body, userId: userId)
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
@APIDefinition(method: .post, path: "/login", auth: .anonymous)
struct LoginRequest {
    struct LoginParameter: Encodable, Sendable {
        let email: String
        let password: String
    }

    typealias APIResponse = AuthResponse

    let body: LoginParameter
    var transport: TransportPolicy<AuthResponse> { .formURLEncoded() }

    init(email: String, password: String) {
        self.body = LoginParameter(email: email, password: password)
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

    var sessionAuthentication: SessionAuthentication { .anonymous }

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
