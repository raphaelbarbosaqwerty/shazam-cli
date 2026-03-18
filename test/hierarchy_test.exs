defmodule Shazam.HierarchyTest do
  use ExUnit.Case

  alias Shazam.Hierarchy

  @agents [
    %{name: "ceo", role: "CEO", supervisor: nil},
    %{name: "gerente", role: "Gerente de Conteúdo", supervisor: "ceo"},
    %{name: "pesquisador", role: "Pesquisador Financeiro", supervisor: "gerente"},
    %{name: "escritor", role: "Redator de Artigos", supervisor: "gerente"},
    %{name: "designer", role: "Designer Gráfico", supervisor: "gerente"}
  ]

  test "find_supervisor retorna o supervisor correto" do
    sup = Hierarchy.find_supervisor(@agents, "pesquisador")
    assert sup.name == "gerente"
  end

  test "find_supervisor retorna nil para o topo" do
    assert Hierarchy.find_supervisor(@agents, "ceo") == nil
  end

  test "find_subordinates retorna subordinados diretos" do
    subs = Hierarchy.find_subordinates(@agents, "gerente")
    names = Enum.map(subs, & &1.name)

    assert "pesquisador" in names
    assert "escritor" in names
    assert "designer" in names
    assert length(subs) == 3
  end

  test "is_superior? detecta hierarquia direta" do
    assert Hierarchy.is_superior?(@agents, "gerente", "pesquisador")
  end

  test "is_superior? detecta hierarquia indireta" do
    assert Hierarchy.is_superior?(@agents, "ceo", "escritor")
  end

  test "is_superior? retorna false para não-superiores" do
    refute Hierarchy.is_superior?(@agents, "pesquisador", "escritor")
  end

  test "chain_of_command retorna cadeia até o topo" do
    chain = Hierarchy.chain_of_command(@agents, "pesquisador")
    names = Enum.map(chain, & &1.name)

    assert names == ["gerente", "ceo"]
  end

  test "best_subordinate_for faz match por role" do
    best = Hierarchy.best_subordinate_for(@agents, "gerente", "Pesquisar dados financeiros sobre ETFs")
    assert best.name == "pesquisador"
  end
end
