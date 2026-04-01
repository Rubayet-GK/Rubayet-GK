let questions = [];
let currentQuestion = {};
let answered = false;
let score = 0;

async function loadQuestions() {
  const res = await fetch("questions.json"); // your questions file
  questions = await res.json();

  // Shuffle questions randomly
  questions = questions.sort(() => 0.5 - Math.random());

  loadQuestion();
}

function loadQuestion() {
  answered = false;
  document.getElementById("result").innerText = "";

  if (questions.length === 0) {
    document.body.innerHTML = `<h2>Quiz Finished!</h2>
                               <p>Your final score: ${score}</p>`;
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
      btn.classList.add("correct");
    }

    if (index === selected && selected !== currentQuestion.answer) {
      btn.classList.add("wrong");
    }
  });

  const result = document.getElementById("result");
  const scoreEl = document.getElementById("score");

  if (selected === currentQuestion.answer) {
    score += 1; // +1 for correct
    result.innerText = "✅ Correct!";
    result.style.color = "green";
  } else {
    score -= 0.5; // -0.5 for wrong
    result.innerText = `❌ Wrong! Correct answer: ${currentQuestion.options[currentQuestion.answer]}`;
    result.style.color = "red";
  }

  // Update live score
  scoreEl.innerText = `Score: ${score}`;

  setTimeout(() => {
    loadQuestion();
  }, 1500);
}

// Start the quiz
loadQuestions();
