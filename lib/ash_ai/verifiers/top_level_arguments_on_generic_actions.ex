# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Verifiers.TopLevelArgumentsOnGenericActions do
  @moduledoc """
  Verifies that `top_level_arguments?` is only set on generic action tools.

  Read, update and destroy tools already use root keys such as `filter`, `limit`,
  `get_by` and the identity fields, so their arguments stay under `input`.
  """
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> AshAi.Info.tools()
    |> Enum.filter(& &1.top_level_arguments?)
    |> Enum.reject(&(action_type(&1, dsl_state, module) in [:action, :unknown]))
    |> case do
      [] ->
        :ok

      invalid_tools ->
        {:error,
         Spark.Error.DslError.exception(
           message: """
           `top_level_arguments?` is only supported on generic action tools.

           The following tools set it on another action type:
           #{Enum.map_join(invalid_tools, "\n", &"  :#{&1.name}")}
           """,
           path: [:tools, :tool, :top_level_arguments?],
           module: module
         )}
    end
  end

  # Resource-level tools carry their own module as the resource.
  defp action_type(%{resource: module, action: action}, dsl_state, module) do
    type_of(Ash.Resource.Info.action(dsl_state, action))
  end

  defp action_type(%{resource: resource, action: action}, _dsl_state, _module) do
    type_of(Ash.Resource.Info.action(resource, action))
  end

  defp type_of(%{type: type}), do: type
  defp type_of(_action), do: :unknown
end
