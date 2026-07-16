const SCROLLABLE_OVERFLOW_VALUES = new Set(["auto", "overlay", "scroll"]);

const AXIS_CONFIG = {
	x: {
		overflow: "overflowX",
		scrollSize: "scrollWidth",
		clientSize: "clientWidth",
		position: "scrollLeft",
	},
	y: {
		overflow: "overflowY",
		scrollSize: "scrollHeight",
		clientSize: "clientHeight",
		position: "scrollTop",
	},
};

const finiteWheelDelta = (value) =>
	typeof value === "number" && Number.isFinite(value) ? value : 0;

export const chartWheelDeltas = (event) => ({
	deltaX: finiteWheelDelta(event?.deltaX),
	deltaY: finiteWheelDelta(event?.deltaY),
});

const defaultGetStyle = (element) => {
	if (
		typeof window !== "undefined" &&
		typeof window.getComputedStyle === "function"
	) {
		return window.getComputedStyle(element);
	}

	return element?.style || {};
};

const canScrollInDirection = (
	element,
	axis,
	delta,
	getStyle,
	allowVisibleOverflow = false,
) => {
	const config = AXIS_CONFIG[axis];
	const style = getStyle(element);
	const overflow = style?.[config.overflow] || style?.overflow || "auto";
	const scrollSize = Number(element?.[config.scrollSize]);
	const clientSize = Number(element?.[config.clientSize]);
	const position = Number(element?.[config.position] || 0);

	if (
		(!SCROLLABLE_OVERFLOW_VALUES.has(overflow) &&
			!(allowVisibleOverflow && overflow === "visible")) ||
		!Number.isFinite(scrollSize) ||
		!Number.isFinite(clientSize) ||
		scrollSize <= clientSize
	) {
		return false;
	}

	const maxPosition = scrollSize - clientSize;

	return delta < 0 ? position > 0 : position < maxPosition;
};

export const findScrollableAncestor = (
	element,
	axis,
	delta,
	getStyle = defaultGetStyle,
) => {
	if (!AXIS_CONFIG[axis] || !delta) return null;

	let candidate = element?.parentElement;

	while (candidate) {
		if (canScrollInDirection(candidate, axis, delta, getStyle))
			return candidate;

		candidate = candidate.parentElement;
	}

	const root =
		typeof document !== "undefined" ? document.scrollingElement : null;

	return root && canScrollInDirection(root, axis, delta, getStyle, true)
		? root
		: null;
};

const scrollByDelta = (element, left, top) => {
	if (!element || (!left && !top)) return false;

	if (typeof element.scrollBy === "function") {
		element.scrollBy({ left, top, behavior: "auto" });
		return true;
	}

	let forwarded = false;

	if (left && typeof element.scrollLeft === "number") {
		element.scrollLeft += left;
		forwarded = true;
	}

	if (top && typeof element.scrollTop === "number") {
		element.scrollTop += top;
		forwarded = true;
	}

	return forwarded;
};

export const forwardWheelDeltas = ({
	event,
	horizontalScroller,
	verticalScroller,
}) => {
	const { deltaX, deltaY } = chartWheelDeltas(event);

	if (
		(!deltaX && !deltaY) ||
		(deltaX && !horizontalScroller) ||
		(deltaY && !verticalScroller)
	) {
		return false;
	}

	if (horizontalScroller === verticalScroller) {
		return scrollByDelta(horizontalScroller, deltaX, deltaY);
	}

	const horizontalForwarded = scrollByDelta(horizontalScroller, deltaX, 0);
	const verticalForwarded = scrollByDelta(verticalScroller, 0, deltaY);

	return horizontalForwarded || verticalForwarded;
};

export const attachChartWheelScroll = (element) => {
	if (!element || element.dataset?.chartWheelScroll !== "page") return null;

	const handleWheel = (event) => {
		event.stopPropagation();

		const { deltaX, deltaY } = chartWheelDeltas(event);
		const horizontalScroller = findScrollableAncestor(element, "x", deltaX);
		const verticalScroller = findScrollableAncestor(element, "y", deltaY);
		const forwarded = forwardWheelDeltas({
			event,
			horizontalScroller,
			verticalScroller,
		});

		if (forwarded && event.cancelable !== false) event.preventDefault();
	};
	const listenerOptions = { capture: true, passive: false };

	element.addEventListener("wheel", handleWheel, listenerOptions);

	let active = true;

	return () => {
		if (!active) return;

		active = false;
		element.removeEventListener("wheel", handleWheel, { capture: true });
	};
};
