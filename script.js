let questions = [];
let currentQuestion = {};
let answered = false;

async function loadQuestions() {
  const res = await fetch("questions.json");
  questions = await res.json();

  questions = questions.sort(() => 0.5 - Math.random());

  loadQuestion();
}

function loadQuestion() {
  answered = false;
  document.getElementById("result").innerText = "";

  if (questions.length === 0) {
    document.body.innerHTML = "<h2>Quiz Finished!</h2>";
    return;
  }

  currentQuestion = questions.pop();

  document.getElementById("question").innerText = currentQuestion.question;

  const answersDiv = document.getElementById("answers");
  answersDiv.innerHTML = "";

  currentQuestion.options.forEach((option, index) => {
    const btn = document.createElement("button");
    btn.innerText = option;

    btn.onclick = () => {
      if (!answered) checkAnswer(index, btn);
    };

    answersDiv.appendChild(btn);
  });
}

function checkAnswer(selected, clickedBtn) {
  answered = true;

  const buttons = document.querySelectorAll("#answers button");

  buttons.forEach((btn, index) => {
    btn.disabled = true;

    if (index === currentQuestion.answer) {
      btn.style.background = "green";
    }

    if (index === selected && selected !== currentQuestion.answer) {
      btn.style.background = "red";
    }
  });

  const result = document.getElementById("result");

  if (selected === currentQuestion.answer) {
    result.innerText = "✅ Correct!";
    result.style.color = "green";
  } else {
    result.innerText = "❌ Wrong!";
    result.style.color = "red";
  }

  setTimeout(() => {
    loadQuestion();
  }, 2000);
}

loadQuestions();
