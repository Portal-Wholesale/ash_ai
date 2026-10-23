# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Mcp.TopLevelArgumentsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Router

  defmodule Resource do
    use Ash.Resource,
      domain: AshAi.Mcp.TopLevelArgumentsTest.Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read]

      action :lookup, :map do
        argument :query, :string, allow_nil?: false, public?: true
        argument :limit, :integer, public?: true

        run fn input, _context ->
          {:ok, %{query: input.arguments.query, limit: Map.get(input.arguments, :limit)}}
        end
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [AshAi]

    resources do
      resource Resource
    end

    tools do
      tool :lookup_top_level, Resource, :lookup do
        top_level_arguments?(true)
        argument :hint, :string

        load fn input ->
          send(self(), {:load_input, input})
          []
        end
      end

      tool :lookup_nested, Resource, :lookup
    end
  end

  @opts [actions: [{Resource, :*}], mcp_resources: []]

  describe "tools/list" do
    test "an opted-in tool lists its action and tool arguments at the root" do
      tool = @opts |> list_tools() |> find_tool("lookup_top_level")

      assert tool["inputSchema"]["properties"] |> Map.keys() |> Enum.sort() ==
               ["hint", "limit", "query"]

      assert tool["inputSchema"]["required"] == ["query"]
      refute Map.has_key?(tool["inputSchema"]["properties"], "input")
    end

    test "a tool without the option keeps its arguments under input" do
      tool = @opts |> list_tools() |> find_tool("lookup_nested")

      assert Map.keys(tool["inputSchema"]["properties"]) == ["input"]
      assert tool["inputSchema"]["required"] == ["input"]
    end
  end

  describe "schema" do
    test "a tool without the option keeps the nested schema in strict and non-strict mode" do
      tool = tool!(:lookup_nested)

      assert AshAi.Tool.Schema.for_tool(tool, strict?: false) == %{
               "type" => "object",
               "properties" => %{
                 "input" => %{
                   "type" => "object",
                   "properties" => %{
                     "query" => %{"type" => "string"},
                     "limit" => %{"type" => "integer"}
                   },
                   "required" => ["query"]
                 }
               },
               "required" => ["input"]
             }

      assert AshAi.Tool.Schema.for_tool(tool, strict?: true) == %{
               "type" => "object",
               "properties" => %{
                 "input" => %{
                   "type" => "object",
                   "properties" => %{
                     "query" => %{"type" => "string"},
                     "limit" => %{"type" => ["integer", "null"]}
                   },
                   "required" => ["limit", "query"],
                   "additionalProperties" => false
                 }
               },
               "required" => ["input"],
               "additionalProperties" => false
             }
    end

    test "an opted-in tool's strict schema is strict at the root" do
      schema = AshAi.Tool.Schema.for_tool(tool!(:lookup_top_level), strict?: true)

      assert schema["additionalProperties"] == false
      assert Enum.sort(schema["required"]) == ["hint", "limit", "query"]
      assert schema["properties"]["query"] == %{"type" => "string"}
    end
  end

  describe "tools/call" do
    test "root arguments run the action, and the load function receives them" do
      result =
        call_tool("lookup_top_level", %{"query" => "acme", "limit" => 5, "hint" => "deals"})

      assert result["isError"] == false
      assert [%{"text" => text}] = result["content"]
      assert Jason.decode!(text) == %{"query" => "acme", "limit" => 5}

      assert_received {:load_input, %{"query" => "acme", "limit" => 5, "hint" => "deals"}}
    end

    test "a nested input fails the unknown-argument check" do
      result = call_tool("lookup_top_level", %{"input" => %{"query" => "acme"}})

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "Unknown arguments provided: input"
    end

    test "a missing required root argument fails naming it" do
      result = call_tool("lookup_top_level", %{"limit" => 5})

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "query"
    end

    test "a tool without the option still reads its arguments from input" do
      result = call_tool("lookup_nested", %{"input" => %{"query" => "acme"}})

      assert result["isError"] == false
      assert [%{"text" => text}] = result["content"]
      assert Jason.decode!(text) == %{"query" => "acme", "limit" => nil}
    end
  end

  describe "verifier" do
    test "refuses the option on a read tool" do
      output =
        capture_io(:stderr, fn ->
          defmodule ReadToolDomain do
            use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

            resources do
              resource AshAi.Mcp.TopLevelArgumentsTest.Resource
            end

            tools do
              tool :list_top_level, AshAi.Mcp.TopLevelArgumentsTest.Resource, :read,
                top_level_arguments?: true
            end
          end
        end)

      assert output =~ "`top_level_arguments?` is only supported on generic action tools"
      assert output =~ ":list_top_level"
    end

    test "accepts the option on a generic action tool" do
      output =
        capture_io(:stderr, fn ->
          defmodule GenericToolDomain do
            use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

            resources do
              resource AshAi.Mcp.TopLevelArgumentsTest.Resource
            end

            tools do
              tool :lookup_again, AshAi.Mcp.TopLevelArgumentsTest.Resource, :lookup,
                top_level_arguments?: true
            end
          end
        end)

      refute output =~ "top_level_arguments?"
    end
  end

  defp tool!(name) do
    @opts
    |> AshAi.exposed_tools()
    |> Enum.find(&(&1.name == name))
  end

  defp list_tools(opts) do
    opts
    |> initialize()
    |> request("tools/list", %{}, opts)
    |> result()
    |> Map.fetch!("tools")
  end

  defp call_tool(name, arguments) do
    @opts
    |> initialize()
    |> request("tools/call", %{"name" => name, "arguments" => arguments}, @opts)
    |> result()
  end

  defp initialize(opts) do
    conn(:post, "/", %{
      "jsonrpc" => "2.0",
      "id" => "init",
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
    })
    |> Router.call(opts)
    |> get_resp_header("mcp-session-id")
    |> List.first()
  end

  defp request(session_id, method, params, opts) do
    conn(:post, "/", %{"jsonrpc" => "2.0", "id" => method, "method" => method, "params" => params})
    |> put_req_header("mcp-session-id", session_id)
    |> Router.call(opts)
  end

  defp result(response), do: Jason.decode!(response.resp_body)["result"]
  defp find_tool(tools, name), do: Enum.find(tools, &(&1["name"] == name))
end
