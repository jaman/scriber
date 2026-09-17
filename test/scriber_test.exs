defmodule ScriberTest do
  use ExUnit.Case, async: false

  alias Drafter.Widget.Registry

  test "registering the widgets actually registers them" do
    for module <- Scriber.widgets() do
      :code.purge(module)
      :code.delete(module)
    end

    Scriber.register_widgets()

    assert Registry.lookup(:cauldron_surface) == Cauldron2D.Drafter.Surface
  end

  test "every widget it claims to register answers to a tag" do
    for module <- Scriber.widgets() do
      Code.ensure_loaded!(module)
      assert function_exported?(module, :component_tag, 0)
      assert is_atom(module.component_tag())
    end
  end
end
