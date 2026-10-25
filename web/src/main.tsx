import { render } from "preact";
import "./ui/styles.css";
import "./ui/insights/insights.css";
import { App } from "./ui/App";

render(<App />, document.getElementById("app")!);
