# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Mcp.ToolAnnotationsTest do
  use ExUnit.Case, async: true
  import Plug.{Conn, Test}

  alias AshAi.Mcp.Router

  # Lets the tool through discovery so the call reaches the policy denial.
  defmodule DiscoveryOnly do
    use Ash.Policy.SimpleCheck

    def match?(_actor, %{context: %{private: %{ash_ai_pre_check?: true}}}, _opts), do: true
    def match?(_actor, _context, _opts), do: false
    def describe(_opts), do: "allowed only during tool discovery"
  end

  defmodule Resource do
    use Ash.Resource,
      domain: AshAi.Mcp.ToolAnnotationsTest.Domain,
      authorizers: [Ash.Policy.Authorizer],
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

      action :protected_result, :map do
        run fn _input, _context -> {:ok, %{}} end
      end
    end

    policies do
      policy action(:protected_result) do
        authorize_if DiscoveryOnly
      end

      policy always() do
        authorize_if always()
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [AshAi]

    resources do
      resource Resource
    end

    tools do
      tool :annotated, Resource, :read,
        title: "Annotated tool",
        annotations: [
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        ]

      tool :partially_annotated, Resource, :read, annotations: [read_only_hint: true]
      tool :plain, Resource, :read
      tool :protected_result, Resource, :protected_result
    end
  end

  defmodule Formatter do
    def format(%Ash.Error.Forbidden.Policy{}), do: "You don't have access to this"
    def format(_error), do: nil

    def format_with_suffix(%Ash.Error.Forbidden.Policy{}, suffix), do: "denied#{suffix}"
    def format_with_suffix(_error, _suffix), do: nil
  end

  @opts [actions: [{Resource, :*}], mcp_resources: []]

  describe "tools/list" do
    test "emits title and every declared annotation hint" do
      tool = @opts |> list_tools() |> find_tool("annotated")

      assert tool["title"] == "Annotated tool"

      assert tool["annotations"] == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }
    end

    test "emits only the hints a tool declares" do
      tool = @opts |> list_tools() |> find_tool("partially_annotated")

      assert tool["annotations"] == %{"readOnlyHint" => true}
      refute Map.has_key?(tool, "title")
    end

    test "a tool without title or annotations lists exactly the previous keys" do
      tool = @opts |> list_tools() |> find_tool("plain")

      assert tool |> Map.keys() |> Enum.sort() == ["description", "inputSchema", "name"]
    end
  end

  describe "DSL validation" do
    test "rejects a non-boolean hint at compile time", %{test: test} do
      domain = Module.concat([__MODULE__, test, Domain])

      assert_raise Spark.Error.DslError, ~r/read_only_hint/, fn ->
        Module.create(
          domain,
          quote do
            use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

            resources do
              resource(unquote(Resource))
            end

            tools do
              tool(:bad, unquote(Resource), :read, annotations: [read_only_hint: "yes"])
            end
          end,
          Macro.Env.location(__ENV__)
        )
      end
    end

    test "rejects an unknown hint at compile time", %{test: test} do
      domain = Module.concat([__MODULE__, test, Domain])

      assert_raise Spark.Error.DslError, ~r/unknown_hint/, fn ->
        Module.create(
          domain,
          quote do
            use Ash.Domain, extensions: [AshAi], validate_config_inclusion?: false

            resources do
              resource(unquote(Resource))
            end

            tools do
              tool(:bad, unquote(Resource), :read, annotations: [unknown_hint: true])
            end
          end,
          Macro.Env.location(__ENV__)
        )
      end
    end
  end

  describe "error_formatter" do
    test "without a formatter a policy denial is \"forbidden\"" do
      assert call_tool("protected_result", @opts) == %{
               "isError" => true,
               "content" => [%{"type" => "text", "text" => "forbidden"}]
             }
    end

    test "a remote function capture formats a policy denial" do
      opts = Keyword.put(@opts, :error_formatter, &Formatter.format/1)

      assert %{"isError" => true, "content" => [%{"text" => "You don't have access to this"}]} =
               call_tool("protected_result", opts)
    end

    test "an MFA formats a policy denial with extra arguments" do
      opts = Keyword.put(@opts, :error_formatter, {Formatter, :format_with_suffix, ["!"]})

      assert %{"isError" => true, "content" => [%{"text" => "denied!"}]} =
               call_tool("protected_result", opts)
    end

    test "returning nil keeps the default text" do
      opts = Keyword.put(@opts, :error_formatter, fn _error -> nil end)

      assert %{"isError" => true, "content" => [%{"text" => "forbidden"}]} =
               call_tool("protected_result", opts)
    end
  end

  defp list_tools(opts) do
    opts
    |> initialize()
    |> request("tools/list", %{}, opts)
    |> result()
    |> Map.fetch!("tools")
  end

  defp call_tool(name, opts) do
    opts
    |> initialize()
    |> request("tools/call", %{"name" => name, "arguments" => %{}}, opts)
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
