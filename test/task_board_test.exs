defmodule Shazam.TaskBoardTest do
  use ExUnit.Case

  alias Shazam.TaskBoard

  test "cria tarefa e retorna com status pendente" do
    {:ok, task} = TaskBoard.create(%{title: "Pesquisar sobre ETFs", assigned_to: "pesquisador"})

    assert task.id =~ "task_"
    assert task.title == "Pesquisar sobre ETFs"
    assert task.status == :pending
    assert task.assigned_to == "pesquisador"
  end

  test "checkout atômico atribui tarefa ao agente" do
    {:ok, task} = TaskBoard.create(%{title: "Tarefa de teste"})
    {:ok, checked} = TaskBoard.checkout(task.id, "escritor")

    assert checked.status == :in_progress
    assert checked.assigned_to == "escritor"
  end

  test "checkout duplo falha" do
    {:ok, task} = TaskBoard.create(%{title: "Tarefa exclusiva"})
    {:ok, _} = TaskBoard.checkout(task.id, "agente1")

    assert {:error, {:already_taken, :in_progress}} = TaskBoard.checkout(task.id, "agente2")
  end

  test "completa tarefa com resultado" do
    {:ok, task} = TaskBoard.create(%{title: "Tarefa completável"})
    {:ok, _} = TaskBoard.checkout(task.id, "agente1")
    {:ok, completed} = TaskBoard.complete(task.id, "Resultado final")

    assert completed.status == :completed
    assert completed.result == "Resultado final"
  end

  test "lista tarefas com filtros" do
    TaskBoard.create(%{title: "T1", assigned_to: "a1"})
    TaskBoard.create(%{title: "T2", assigned_to: "a2"})
    TaskBoard.create(%{title: "T3", assigned_to: "a1"})

    tasks_a1 = TaskBoard.list(%{assigned_to: "a1"})
    assert length(tasks_a1) >= 2
    assert Enum.all?(tasks_a1, &(&1.assigned_to == "a1"))
  end

  test "goal ancestry retorna cadeia de tarefas pai" do
    {:ok, parent} = TaskBoard.create(%{title: "Meta principal"})

    {:ok, child} =
      TaskBoard.create(%{title: "Subtarefa", parent_task_id: parent.id})

    {:ok, grandchild} =
      TaskBoard.create(%{title: "Sub-subtarefa", parent_task_id: child.id})

    ancestry = TaskBoard.goal_ancestry(grandchild.id)

    assert length(ancestry) == 3
    assert hd(ancestry).title == "Meta principal"
    assert List.last(ancestry).title == "Sub-subtarefa"
  end

  test "pending_for retorna tarefas pendentes de um agente" do
    TaskBoard.create(%{title: "Pendente", assigned_to: "bot"})
    pending = TaskBoard.pending_for("bot")

    assert length(pending) >= 1
    assert Enum.all?(pending, &(&1.status == :pending))
    assert Enum.all?(pending, &(&1.assigned_to == "bot"))
  end

  test "fail marca tarefa como falha" do
    {:ok, task} = TaskBoard.create(%{title: "Vai falhar"})
    {:ok, _} = TaskBoard.checkout(task.id, "agente")
    # fail funciona em qualquer status
    {:ok, failed} = TaskBoard.fail(task.id, "timeout")

    assert failed.status == :failed
    assert failed.result == {:error, "timeout"}
  end
end
