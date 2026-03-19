//
//  RealWorldAPIExample.swift
//  InnoNetwork Examples
//
//  This file demonstrates real-world API usage scenarios.
//  Shows common workflows like authentication, pagination, CRUD operations.
//

import Foundation
import InnoNetwork

// MARK: - 1. Client Configuration

private let clientConfiguration = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)

// MARK: - 2. Data Models

struct User: Decodable, Identifiable {
    let id: Int
    let name: String
    let email: String
    let username: String
}

struct Post: Decodable, Identifiable {
    let id: Int
    let title: String
    let body: String
    let userId: Int
}

struct Comment: Decodable, Identifiable {
    let id: Int
    let postId: Int
    let name: String
    let email: String
    let body: String
}

struct LoginRequest: Encodable {
    let username: String
    let password: String
}

struct LoginResponse: Decodable {
    let token: String
    let userId: Int
}

// MARK: - 3. API Definitions

// Scenario 1: User Login
actor LoginUser: APIDefinition {
    typealias Parameter = LoginRequest
    typealias APIResponse = LoginResponse

    let parameters: LoginRequest?

    var method: HTTPMethod { .post }
    var path: String { "/login" }

    init(username: String, password: String) {
        self.parameters = LoginRequest(username: username, password: password)
    }
}

// Scenario 2: Fetch All Posts (with pagination)
actor FetchPosts: APIDefinition {
    struct QueryParameter: Encodable {
        let _page: Int
        let _limit: Int
    }

    typealias Parameter = QueryParameter
    typealias APIResponse = [Post]

    let parameters: QueryParameter?

    var method: HTTPMethod { .get }
    var path: String { "/posts" }

    init(page: Int = 1, limit: Int = 10) {
        self.parameters = QueryParameter(_page: page, _limit: limit)
    }
}

// Scenario 3: Fetch Single Post Details
actor FetchPostDetail: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    let postId: Int

    var method: HTTPMethod { .get }
    var path: String { "/posts/\(postId)" }

    init(postId: Int) {
        self.postId = postId
    }
}

// Scenario 4: Fetch Comments for a Post
actor FetchPostComments: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = [Comment]

    let postId: Int

    var method: HTTPMethod { .get }
    var path: String { "/posts/\(postId)/comments" }

    init(postId: Int) {
        self.postId = postId
    }
}

// Scenario 5: Create New Post
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

    init(title: String, body: String, userId: Int = 1) {
        self.parameters = PostParameter(title: title, body: body, userId: userId)
    }
}

// Scenario 6: Update Post
actor UpdatePost: APIDefinition {
    struct PostParameter: Encodable {
        let id: Int
        let title: String
        let body: String
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    let parameters: PostParameter?
    let postId: Int

    var method: HTTPMethod { .put }
    var path: String { "/posts/\(postId)" }

    init(id: Int, title: String, body: String) {
        self.postId = id
        self.parameters = PostParameter(id: id, title: title, body: body)
    }
}

// Scenario 7: Delete Post
actor DeletePost: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyResponse

    let postId: Int

    var method: HTTPMethod { .delete }
    var path: String { "/posts/\(postId)" }

    init(postId: Int) {
        self.postId = postId
    }
}

// Scenario 8: Fetch User Profile
actor FetchUserProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    let userId: Int

    var method: HTTPMethod { .get }
    var path: String { "/users/\(userId)" }

    init(userId: Int) {
        self.userId = userId
    }
}

// Scenario 9: Search Posts by User
actor SearchUserPosts: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = [Post]

    let userId: Int

    var method: HTTPMethod { .get }
    var path: String { "/posts" }
    var parameters: QueryParameter? { QueryParameter(userId: userId) }

    struct QueryParameter: Encodable, Sendable {
        let userId: Int
    }

    init(userId: Int) {
        self.userId = userId
    }
}

// MARK: - 4. Real-World Scenarios

actor RealWorldAPIExample {
    let client: DefaultNetworkClient

    init() {
        self.client = DefaultNetworkClient(configuration: clientConfiguration)
    }

    // Scenario 1: User Login
    func loginScenario() async {
        print("=== Scenario 1: User Login ===")
        do {
            let response = try await client.request(LoginUser(username: "user", password: "pass"))
            print("✅ Login Successful!")
            print("Token: \(response.token)")
            print("User ID: \(response.userId)")
        } catch {
            print("❌ Login failed: \(error)")
        }
    }

    // Scenario 2: Fetch Posts with Pagination
    func fetchPostsScenario() async {
        print("\n=== Scenario 2: Fetch Posts (Pagination) ===")
        do {
            let posts = try await client.request(FetchPosts(page: 1, limit: 5))
            print("✅ Fetched \(posts.count) posts (Page 1)")
            for post in posts.prefix(3) {
                print("  - \(post.title)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Scenario 3: Fetch Post Details with Comments
    func fetchPostDetailScenario() async {
        print("\n=== Scenario 3: Fetch Post Details & Comments ===")
        do {
            // Fetch post details
            let post = try await client.request(FetchPostDetail(postId: 1))
            print("✅ Post Details:")
            print("  Title: \(post.title)")
            print("  Body: \(post.body)")

            // Fetch comments for this post
            let comments = try await client.request(FetchPostComments(postId: 1))
            print("  Comments: \(comments.count) total")
            for comment in comments.prefix(2) {
                print("    - \(comment.name) (\(comment.email))")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Scenario 4: Create and Update Post
    func createAndUpdateScenario() async {
        print("\n=== Scenario 4: Create & Update Post ===")
        do {
            // Create new post
            let newPost = try await client.request(CreatePost(
                title: "My New Post",
                body: "This is a sample post content"
            ))
            print("✅ Created post #\(newPost.id)")

            // Update the post
            let updatedPost = try await client.request(UpdatePost(
                id: 1,
                title: "Updated: \(newPost.title)",
                body: "Updated body content"
            ))
            print("✅ Updated post: \(updatedPost.title)")
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Scenario 5: Complete CRUD Workflow
    func crudWorkflowScenario() async {
        print("\n=== Scenario 5: Complete CRUD Workflow ===")
        do {
            // CREATE: Add new post
            print("1. Creating post...")
            let createdPost = try await client.request(CreatePost(
                title: "CRUD Test Post",
                body: "Testing CRUD operations"
            ))
            print("   ✅ Created post #\(createdPost.id)")

            // READ: Fetch the post
            print("2. Reading post...")
            let fetchedPost = try await client.request(FetchPostDetail(postId: 1))
            print("   ✅ Fetched: \(fetchedPost.title)")

            // UPDATE: Modify the post
            print("3. Updating post...")
            let updatedPost = try await client.request(UpdatePost(
                id: 1,
                title: "[UPDATED] \(fetchedPost.title)",
                body: "Content has been updated"
            ))
            print("   ✅ Updated: \(updatedPost.title)")

            // DELETE: Remove the post
            print("4. Deleting post...")
            try await client.request(DeletePost(postId: 1))
            print("   ✅ Deleted post")

            print("\n✅ Complete CRUD workflow finished!")
        } catch {
            print("❌ Error in CRUD workflow: \(error)")
        }
    }

    // Scenario 6: User Profile and Posts
    func userProfileScenario() async {
        print("\n=== Scenario 6: User Profile & Posts ===")
        do {
            // Fetch user profile
            let user = try await client.request(FetchUserProfile(userId: 1))
            print("✅ User Profile:")
            print("  Name: \(user.name)")
            print("  Username: @\(user.username)")
            print("  Email: \(user.email)")

            // Fetch user's posts
            let userPosts = try await client.request(SearchUserPosts(userId: 1))
            print("\n✅ User's Posts (\(userPosts.count) total):")
            for post in userPosts.prefix(3) {
                print("  - \(post.title)")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Scenario 7: Batch Processing - Fetch Multiple Pages
    func batchProcessingScenario() async {
        print("\n=== Scenario 7: Batch Processing (Multiple Pages) ===")
        var allPosts: [Post] = []
        let totalPages = 3

        do {
            for page in 1...totalPages {
                let posts = try await client.request(FetchPosts(page: page, limit: 5))
                allPosts.append(contentsOf: posts)
                print("✅ Fetched page \(page): \(posts.count) posts")
            }

            print("\n✅ Total posts fetched: \(allPosts.count)")
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // Run all scenarios
    func runAllScenarios() async {
        await loginScenario()
        await fetchPostsScenario()
        await fetchPostDetailScenario()
        await createAndUpdateScenario()
        await crudWorkflowScenario()
        await userProfileScenario()
        await batchProcessingScenario()

        print("\n=== All scenarios completed ===")
    }
}

// MARK: - 5. Running the Examples

@main
struct RealWorldAPIApp {
    static func main() async {
        let example = RealWorldAPIExample()
        await example.runAllScenarios()
    }
}
