# Real-World API Examples

This example demonstrates common real-world API scenarios using InnoNetwork.

## Setup

```swift
import InnoNetwork

struct BlogAPI: APIConfigure {
    var host: String { "jsonplaceholder.typicode.com" }
    var basePath: String { "" }
}

API.configure(BlogAPI())
```

## Running the Examples

```bash
# From the InnoNetwork directory
cd Examples/RealWorldAPI
swift RealWorldAPIExample.swift
```

## Covered Scenarios

This example covers:

1. **User Authentication**: Simulated login flow
2. **Paginated Data Fetching**: Fetching posts with pagination
3. **Creating New Posts**: POST requests with parameters
4. **Fetching Post Details**: Get single post with comments
5. **Updating and Deleting Posts**: Full CRUD operations
6. **User Profile Management**: Fetching user information
7. **Batch Processing**: Fetching multiple pages in parallel

These scenarios represent typical workflows in modern applications like social media, blogs, e-commerce, etc.

## Common Patterns

### Creating an API Definition with Parameters

```swift
actor CreatePost: APIDefinition {
    struct PostParameter: Encodable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    let parameters: PostParameter?

    var method: HTTPMethod { .post }
    var path: String { "/posts" }

    var configuration: NetworkConfiguration? {
        NetworkConfiguration(baseURL: URL(string: "https://jsonplaceholder.typicode.com")!)
    }

    init(title: String, body: String, userId: Int = 1) {
        self.parameters = PostParameter(title: title, body: body, userId: userId)
    }
}
```

### Making Requests

```swift
let client = try! DefaultNetworkClient(configuration: BlogAPI())

// Simple GET request
let posts = try await client.request(FetchPosts(page: 1, limit: 10))

// POST request with parameters
let newPost = try await client.request(CreatePost(
    title: "My Post",
    body: "Post content"
))

// GET with path parameter
let post = try await client.request(FetchPostDetail(postId: 1))
```

## Workflow Examples

### Complete CRUD Workflow

1. **CREATE**: Add new post
```swift
let createdPost = try await client.request(CreatePost(
    title: "New Post",
    body: "Content here"
))
print("Created post #\(createdPost.id ?? 0)")
```

2. **READ**: Fetch post
```swift
let fetchedPost = try await client.request(FetchPostDetail(postId: 1))
print("Fetched: \(fetchedPost.title)")
```

3. **UPDATE**: Modify post
```swift
let updatedPost = try await client.request(UpdatePost(
    id: 1,
    title: "Updated Title",
    body: "Updated content"
))
print("Updated: \(updatedPost.title)")
```

4. **DELETE**: Remove post
```swift
try await client.request(DeletePost(postId: 1))
print("Deleted post #1")
```

### Fetching Related Data

```swift
// Fetch post details
let post = try await client.request(FetchPostDetail(postId: 1))
print("Post: \(post.title)")

// Fetch comments for this post
let comments = try await client.request(FetchPostComments(postId: 1))
print("Comments: \(comments.count)")

for comment in comments.prefix(3) {
    print("  - \(comment.name) (\(comment.email))")
}
```

### Batch Processing

```swift
// Fetch multiple pages concurrently
var allPosts: [Post] = []
var totalPages = 3

for page in 1...totalPages {
    let posts = try await client.request(FetchPosts(page: page, limit: 10))
    allPosts.append(contentsOf: posts)
    print("Fetched page \(page): \(posts.count) posts")
}

print("Total posts: \(allPosts.count)")
```
