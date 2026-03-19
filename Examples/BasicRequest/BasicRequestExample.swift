//
//  BasicRequestExample.swift
//  InnoNetwork Examples
//
//  This file demonstrates basic HTTP request usage with InnoNetwork.
//  GET, POST, PUT, DELETE requests using JSONPlaceholder API.
//

import Foundation
import InnoNetwork

// MARK: - 1. Client Configuration

private let clientConfiguration = NetworkConfiguration.safeDefaults(
    baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
)

// MARK: - 2. Data Models

struct Todo: Decodable, Sendable {
    let id: Int
    let title: String
    let completed: Bool
    let userId: Int
}

struct Post: Codable, Sendable {
    let id: Int?
    let title: String
    let body: String
    let userId: Int
}

// MARK: - 3. API Definitions

struct GetTodos: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = [Todo]

    var method: HTTPMethod { .get }
    var path: String { "/todos" }
}

struct GetPost: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Post

    let postId: Int

    var method: HTTPMethod { .get }
    var path: String { "/posts/\(postId)" }
}

struct CreatePost: APIDefinition {
    struct PostParameter: Encodable, Sendable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    var parameters: PostParameter?

    var method: HTTPMethod { .post }
    var path: String { "/posts" }

    init(title: String, body: String, userId: Int = 1) {
        self.parameters = PostParameter(title: title, body: body, userId: userId)
    }
}

struct UpdatePost: APIDefinition {
    struct PostParameter: Encodable, Sendable {
        let id: Int
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    var parameters: PostParameter?
    let postId: Int

    var method: HTTPMethod { .put }
    var path: String { "/posts/\(postId)" }

    init(id: Int, title: String, body: String, userId: Int = 1) {
        self.postId = id
        self.parameters = PostParameter(id: id, title: title, body: body, userId: userId)
    }
}

struct PatchPost: APIDefinition {
    struct PostParameter: Encodable, Sendable {
        let title: String?
        let body: String?
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    var parameters: PostParameter?

    var method: HTTPMethod { .patch }
    var path: String { "/posts/1" }

    init(title: String? = nil, body: String? = nil) {
        self.parameters = PostParameter(title: title, body: body)
    }
}

struct DeletePost: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = EmptyResponse

    let postId: Int

    var method: HTTPMethod { .delete }
    var path: String { "/posts/\(postId)" }
}

// MARK: - 4. Usage Examples

@MainActor
class BasicRequestExample {
    let client: DefaultNetworkClient

    init() {
        self.client = DefaultNetworkClient(configuration: clientConfiguration)
    }

    func getAllTodos() async {
        print("=== GET: Fetch all todos ===")
        do {
            let todos = try await client.request(GetTodos())
            print("Success! Fetched \(todos.count) todos")
            print("First todo: \(todos.first?.title ?? "N/A")")
        } catch {
            print("Error: \(error)")
        }
    }

    func getSinglePost() async {
        print("\n=== GET: Fetch single post ===")
        do {
            let post = try await client.request(GetPost(postId: 1))
            print("Success! Post #\(post.id ?? 0): \(post.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func createNewPost() async {
        print("\n=== POST: Create new post ===")
        do {
            let newPost = try await client.request(CreatePost(
                title: "My New Post",
                body: "This is the content of my new post",
                userId: 1
            ))
            print("Success! Created post #\(newPost.id ?? 0)")
            print("Title: \(newPost.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func updatePost() async {
        print("\n=== PUT: Update post ===")
        do {
            let updatedPost = try await client.request(UpdatePost(
                id: 1,
                title: "Updated Title",
                body: "Updated body content",
                userId: 1
            ))
            print("Success! Updated post #\(updatedPost.id ?? 0)")
            print("New title: \(updatedPost.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func patchPost() async {
        print("\n=== PATCH: Partially update post ===")
        do {
            let patchedPost = try await client.request(PatchPost(title: "Patched Title"))
            print("Success! Patched post #\(patchedPost.id ?? 0)")
            print("New title: \(patchedPost.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func deletePost() async {
        print("\n=== DELETE: Delete post ===")
        do {
            _ = try await client.request(DeletePost(postId: 1))
            print("Success! Deleted post #1")
        } catch {
            print("Error: \(error)")
        }
    }

    func runAllExamples() async {
        await getAllTodos()
        await getSinglePost()
        await createNewPost()
        await updatePost()
        await patchPost()
        await deletePost()
    }
}

// MARK: - 5. Running the Examples

@main
struct BasicRequestApp {
    static func main() async {
        let example = BasicRequestExample()
        await example.runAllExamples()
    }
}
