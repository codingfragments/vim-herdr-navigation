//! Direction enum + dir→(key,axis) map. Mirrors the `case` block in navigate.sh.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    H,
    V,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Down,
    Up,
    Right,
}

impl Direction {
    pub fn from_str(s: &str) -> Result<Self, ()> {
        Ok(match s {
            "left" => Direction::Left,
            "down" => Direction::Down,
            "up" => Direction::Up,
            "right" => Direction::Right,
            _ => return Err(()),
        })
    }

    /// The Ctrl chord forwarded into Vim (ctrl+h/j/k/l).
    pub fn key(&self) -> &'static str {
        match self {
            Direction::Left => "ctrl+h",
            Direction::Down => "ctrl+j",
            Direction::Up => "ctrl+k",
            Direction::Right => "ctrl+l",
        }
    }

    /// Which axis this direction moves along. left/right → H, up/down → V.
    pub fn axis(&self) -> Axis {
        match self {
            Direction::Left | Direction::Right => Axis::H,
            Direction::Up | Direction::Down => Axis::V,
        }
    }

    /// The direction name string passed to `herdr pane focus --direction`.
    pub fn name(&self) -> &'static str {
        match self {
            Direction::Left => "left",
            Direction::Down => "down",
            Direction::Up => "up",
            Direction::Right => "right",
        }
    }
}
